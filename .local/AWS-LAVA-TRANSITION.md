# AWS account transition: bene -> lava

2026-09-11. **`bene` expired at 12:03 UTC; I discovered it at 12:42, i.e. 39 minutes after the fact.**

## What was lost
Four benchmark boxes were mid-run under `Owner=agent-a2abench` (x86 `m5d.metal`, aarch64 `c7gd.metal`,
two `c5.4xlarge` drivers). Credentials are now dead:

    aws sts get-caller-identity  -> InvalidClientTokenId
    aws ec2 describe-instances   -> AuthFailure

So the instances cannot be queried, salvaged, or terminated through the API, and **the sixth benchmark
attempt is lost**. AWS will reap the boxes with the account; there is no orphan to clean up because
there is no longer an account to clean it in.

**Lesson, and it is mine:** I knew `bene` was a burner and never asked for its expiry date. A benchmark
that takes hours was launched into an account with under an hour left on it. **Any future burner gets its
expiry recorded in the plan on day one, and long runs get checked against it before launch.**

## lava scaffold, built now so the next run is not blocked on setup

    account            769093516156  (arn:aws:iam::769093516156:user/lava)
    region             us-east-2
    quota L-1216C47A   5 (default) -- request for 200 already OPEN (CASE_OPENED 08:40 EDT)
    vpc                vpc-097adc381027f16e1  (default)
    subnets            subnet-0230d1c45d8a098a7 (us-east-2a)
                       subnet-0b90d606a743759f9 (us-east-2c)
                       subnet-01c9a1bb639c2f8ef (us-east-2b)
    keypair            osv-lava      -> private key at ~/.ssh/osv-lava (0600)
    security group     osv-bench = sg-0a954e440478e063d
                         tcp/22 from 73.4.58.126/32
                         all protocols from 172.31.0.0/16
    AMIs (region-scoped, re-resolved for this account)
      AL2023 x86_64    ami-0eff088391f589f50
      AL2023 arm64     ami-01c02d0105285e20d
      Ubuntu 24.04     ami-00adec9774170bad2   (unchanged from bene - same region)

## The blocking constraint
**Quota is 5 vCPU.** A pending request asks for **200**, which is enough for the x86 arm
(`m5d.metal` 96 + a 16-vCPU driver = 112) but **not** the full parallel matrix that needs ~192 plus
headroom. Note the prior account's 192->512 request closed in ~40 minutes while a 512->640 took longer,
so turnaround is unpredictable; **file early, do not plan around a deadline.**

## Sequencing consequence
Until quota lands, no benchmark arm can run - `m5d.metal` alone is 96 vCPU against a limit of 5. So:
1. Wait on the 200-vCPU request (already open, not filed by me).
2. When it lands, run **x86 first** (112 vCPU fits in 200), then aarch64, then Firecracker.
3. If 200 proves insufficient for parallelism, file a follow-up increase rather than serialising
   everything - but only after the first is granted, since only one request per quota may be open.

## What survives the transition unaffected
All the work that matters is **off-box already**: PRs #1502/#1503/#1504 against master, the three #1455
commits on `gh-fork/wip/fork-posix-fdtable-v5`, the benchmark base `gh-fork/fix/tcb-psabi-guards` (TCB
fix + both fork halves, verified), every `.local/` result document, and the repinned branches. **The
transition costs a benchmark run, not any fix.**


## UPDATE: the first quota request was PARTIALLY granted, and lava is shared

    request for 200  ->  CASE_CLOSED, granted as 32   (not 200)
    effective quota  ->  32 vCPU

And **lava is not exclusively ours**: another project is already running a `c6id.8xlarge`
(`xtc-abba-20260911-124454`, launched 12:45 UTC) which consumes **32 of the 32**. So free capacity is
**zero**, and even an empty account at 32 could not host a benchmark:

    m5d.metal   96  -> NO      c7gd.metal  64  -> NO
    m5zn.metal  48  -> NO      z1d.metal   48  -> NO

**No metal instance fits in 32, and without metal there is no /dev/kvm, so there is no valid
benchmark** - TCG timings are meaningless for latency or throughput. This is the same wall hit in the
previous account, but harder: there the shortfall was contention, here it is the quota itself.

**Follow-up request filed**: `d5e96350...oHP54b7R`, 32 -> **640**, PENDING. Only one request per quota
may be open at a time, which is why this could not be filed until the first closed.

## Scaffold verified working end to end
A dry-run launch against the new keypair, security group and subnet returned:

    DryRunOperation: Request would have succeeded, but DryRun flag is set.

So the only thing standing between us and a benchmark is quota, not configuration. Nothing to clean in
lava: 0 instances of ours, 0 unattached volumes.

## Standing rule added for burner accounts
`bene` died mid-benchmark because I never recorded its expiry. **Every burner account now gets its
expiry captured in the plan at first use, and any run longer than an hour is checked against the
remaining time before launch.** The cost this time was one benchmark attempt; it could as easily have
been an unrecoverable fix, and only the push-early discipline made that not so.

## Attempt 7 launched on lava (2026-09-11)

**The 640-vCPU request was APPROVED** (`d5e96350...`, CASE_CLOSED at 640), so the full matrix fits.

    i-0ce983c4cb91921cf  m5d.metal    a2abench7-x86-m5d
    i-031434d1538558de9  c7gd.metal   a2abench7-arm-c7gd
    i-06b5f679718f7e389  c5.4xlarge   a2abench7-drv-x86
    i-02162e8211e14b30f  c5.4xlarge   a2abench7-drv-arm

All tagged `Owner=agent-a2abench7`, recorded to `.local/a2abench7/` immediately.

### A brief error of mine, corrected before it cost anything
I carried `ami-00adec9774170bad2` forward from the old account's notes as the Ubuntu driver AMI without
re-checking its architecture. It is **x86_64 only** - the name says `amd64` outright - so the arm-side
driver could never have used it. The agent caught it at launch time and used a second `c5.4xlarge`
instead.

**Its reasoning is better than my brief's:** the driver is a pure TCP client, so its architecture is not
a confound, and **two identical drivers remove a variable rather than adding one** - any cross-ISA
difference then attributes to the guest rather than to the load generator. Recorded as a deliberate
choice, not a workaround.

### Capacity: shared account, and the numbers move
The agent measured ~592 of 640 in use at launch; I measured **352 of 640, 288 free** minutes later.
Other projects (`solnix-*` at 10x m5.4xlarge, an `i4i.metal`, `xtc-*`) churn visibly. Told it to
**re-measure before any further launch** rather than trust either figure. More headroom than it thought,
so nothing at risk.

### The bar for this attempt
**One complete VU8 cell with three repeats, written to `.local/a2abench7/` on the workstation, before
anything else.** Six attempts have died before a single cell completed - four to context exhaustion, one
to account expiry, one to a guest crash. **A single recorded cell would be the first real NOPM number on
a fixed base in this programme.** Breadth comes after that exists on disk.
