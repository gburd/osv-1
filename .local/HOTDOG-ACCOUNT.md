# hotdog AWS account (replaces lava, which expired 2026-09-18 12:20 UTC)

## FACTS (verified 2026-09-18)
- Account: 585335547908, IAM user hotdog, profile `hotdog` in ~/.aws/credentials.
- MUST pass --region explicitly (no region in the profile config): us-east-2.
- Keypair: osv-hotdog (created; private key ~/.ssh/osv-hotdog, chmod 600).
- Security group: sg-0a0fec26afe57cd43 (osv-bench, default VPC vpc-04491918f37a14019). SSH:22 ingress is
  SCOPED TO MY /32 ONLY (73.4.58.126/32 as of 2026-09-18) - NEVER 0.0.0.0/0 (see the hard rule below).
  If my public IP changes, re-scope: revoke the old /32, authorize the new /32. Re-verify no 0.0.0.0/0.
- Subnets (default VPC): us-east-2a subnet-04a66ccb68b2a2f13, 2b subnet-09c88ac2e5d1da3f6,
  2c subnet-0852bcf2833df76ef.

## BLOCKER: vCPU quota
- Standard On-Demand vCPU (L-1216C47A) EFFECTIVE = 5. m5d.metal = 96 vCPU -> CANNOT launch.
- An increase request to 1152 is OPEN (CASE_OPENED 2026-09-18 07:55, id f3ddb129...Qr4yW2o3), NOT granted.
  Also L-34B43A08 (spot?) pending to 32. => HARD-BLOCKED until AWS grants the 1152 request.
- Check grant: AWS_PROFILE=hotdog aws service-quotas get-service-quota --region us-east-2 \
    --service-code ec2 --quota-code L-1216C47A --query 'Quota.Value' --output text   (launch when >=96)

## SUBSTRATE DIRECTIVE (standing): NixOS(pref) > Debian > Fedora, NEVER Amazon Linux. Debian 12
## ami-0dc1629a58a7d6458 (x86) ships native qemu 7.2.22 that boots OSv with -M pc (q35 hangs, #1498).
## Raw NVMe passthrough (cache=none aio=native), NOT raw-file-on-XFS.

## PENDING HIGH-VALUE RUN (the moment quota grants): adaptive-idle-spin TWO GATES + a2a VU32->192
- Base: gh-fork bank/sched-adaptive-idle-spin @ 1685b6511 (adaptive v2, +65% op/s isolate). apps 3f93f43.
- Gate 1 (idle-regression A/B): CLEAN measurement on the metal (the prior nested-container proxy read 0
  on both arms - inconclusive). adaptive-v2 vs fixed-10000 guest CPU on a mostly-idle guest.
- Gate 2 (a2a gold test): does the VU32 intermittent low-mode DISAPPEAR? Fresh-boot-per-cell, io_uring,
  OSv vs matched Linux, VU32 -> VU192 (operator: test VU32 to 192), 3 reps each, p99, qemu-cpu discriminator
  per rep. The fixed-count VU32 had a 93k waiting-mode low-rep; adaptive PASSES if all reps cluster high +
  the 0.5-vCPU-waiting signature is gone, AND OSv holds/scales VU32->64->128->192 vs Linux.
- Bench-base-gate must PASS on the built base (all 9 markers). io_uring both sides (OSv PG rebuilt
  --with-liburing already on this lineage). Never SIGKILL qemu mid-CHECKPOINT (tears the ZFS pool).

## QUOTA GRANTED 2026-09-18: L-1216C47A = 1152 vCPU (request CASE_CLOSED 08:02). m5d.metal launchable.
## GATES RUN COMPLETE 2026-09-18 (agent-gates, boxes i-07cd70356cef08c3a metal + i-0d81859ea71589291
## driver - BOTH TERMINATED, 0 agent-gates orphans, 0 available volumes, SG stays /32+intra-SG-5432, no
## 0.0.0.0/0). RESULTS in .local/gates/RESULT.md. GATE 1 PASS (adaptive idle CPU 20.5% vs fixed 63.5% of
## one core - idle-safe, default-on-able). GATE 2 VU32: adaptive clean, 4 healthy CPU-saturated reps
## (median 208k NOPM, no idle->wake low-mode); Linux VU32=338k (ratio 0.62). NEW FINDING at VU64: a
## DISTINCT, OSv-SPECIFIC, PERMANENT lost-wakeup DEADLOCK on the WAL-commit/ZIL-completion->waiter path
## (healthy ~60s -> commit_delta=2/NVMe=0/qemu-idle, never recovers; io_uring AND worker AND fixed-10000
## all wedge; Linux scales to 486k on identical stack). NOT fixed by adaptive-idle-spin (different layer),
## likely pre-existing (VU64 untested before). adaptive-idle-spin = real PARTIAL win; VU64 wedge is the
## next named residual. Master-rebase + PR NOT prepped (landed to save box time; delegating agent handles).
## The two other running instances (c6id.8xlarge, c6id.24xlarge, Owner=None) are NOT agent-gates - untouched.

## SHARED ACCOUNT (2026-09-18): hotdog is SHARED with solnix (Owner=gregburd). Pre-existing at gates launch:
## c5.xlarge i-0e5c817e06717ff8e + a 21GiB available volume = solnix's, NOT ours. TIDY BOUNDARY: only
## terminate/delete resources tagged Owner=agent-* that WE created (LaunchTime-gated); NEVER touch
## Owner=gregburd/solnix resources. Same discipline as lava (which churned solnix/xtc/pgweave visibly).
## GATES BOXES (ours): METAL i-07cd70356cef08c3a + DRV i-0d81859ea71589291, Owner=agent-gates.

## GATES EARLY RESULTS (2026-09-18, agent df2b1866):
GATE 1 PASS (decisive): adaptive-v2 idle CPU 20.5% of one core vs fixed-10000 63.5% (host qemu utime+stime,
2 reps each) - adaptive burns ~1/3 the idle CPU = IDLE-SAFE + promotable DEFAULT-ON on the idle axis.
Reverses the prior inconclusive nested-proxy (which read 0).
GATE 2 (in progress): OSv adaptive VU32 = 246458/229755/186862/180014 NOPM, ALL CPU-saturated (qemu
2260-2305% = ~23 vCPU), NO 0.5-vCPU-waiting low-mode. (The fixed-count a2a had a 93k rep at 0.5 vCPU.)
r4 = HammerDB-6.0 gather-hang (NVMe=0, no TEST RESULT, Tcl exit = never loaded) = harness artifact, NOT
the wakeup low-mode (correctly distinguished; re-running). Sweep at VU64.
STEERED to make gate 2 CONCLUSIVE: (1) the decisive VU32 fixed-vs-adaptive A/B on THIS box (does FIXED
reproduce the low-mode here while adaptive does not? - low-mode-gone must be PROVEN by the A/B, not
inferred from 4 reps not hitting it); (2) the matched LINUX VU32->192 arm (parity = OSv-vs-Linux; qemu-cpu
discriminator on Linux too). Priority if budget-cut: VU32 A/B + Linux VU32/64 > reaching VU192 both sides.
SG stays /32; solnix c5.xlarge i-0e5c817e06717ff8e + its volume NOT ours (do not touch).

## VU64 WEDGE - a NEW distinct residual (2026-09-18, agent df2b1866):
At VU64 (OSv, adaptive-v2, io_uring), a HARD WEDGE (not the VU32 idle->wake low-mode): 0 NOPM, ~66/69
backends on LWLock:WALWrite, checkpointer in CheckpointDelayStart, bgwriter hibernating, NVMe IO=0 for 30s+,
qemu ~0.3 vCPU (idle, NOT spinning). Diagnosis: a lost-wakeup stall/deadlock on the WAL-commit /
io_uring-completion path - the flush completion wakeup is lost, the WALWrite holder never wakes to release,
waiters never signaled. adaptive-idle-spin does NOT fix this (it targets idle->wake, not completion->waiter).
VU32 was clean (4 healthy CPU-saturated reps 180-246k). So adaptive is a PARTIAL win: GATE 1 PASS (idle-safe,
1/3 idle CPU) + VU32-clean, but a DISTINCT wedge caps VU64+. LIKELY PRE-EXISTING (the a2a only reached VU32;
VU64 is untested territory) not a regression - to be confirmed by the fixed-vs-adaptive VU64 A/B.
DISCRIMINATORS steered (to LOCALIZE, not just characterize): (1) watch-longer = deadlock (permanent) vs
slow-stall (drains)? (2) io_uring-vs-WORKER VU64 A/B = is the lost wake in OSv's io_uring completion path
(core/io_uring.cc) or the ZFS-ZIL/WAL-commit path? (3) fixed-vs-adaptive VU64 = rules adaptive in/out +
confirms pre-existing. (4) matched LINUX VU64 = PG/ZFS-ceiling vs OSv-specific. VU128/192 MOOT until VU64
understood (wedge caps the sweep). HONEST: do NOT overclaim "residual fixed" (VU64 refutes the blanket
version); do NOT let VU64 erase the real GATE 1 + VU32 wins. Capture the wedge signature for next root-cause.
