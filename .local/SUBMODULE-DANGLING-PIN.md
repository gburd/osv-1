
# SCOPE CORRECTED TWICE (2026-09-08): 104 branches, but only ONE open PR

Agent 7ffcfa67 corrected my scoping again, and this time I under-stated the spread while
over-stating the harm. Both verified by me.

## Actual spread: 104 branches, not two

    git for-each-ref refs/heads refs/remotes | compare `git ls-tree <ref> apps`
      -> 104 refs pin the dangling 57c607984393...

My "x86 lineage, two branches" framing was wrong by two orders of magnitude. Also
**`wip/pg-v26-faultfix` does not exist locally at all** (`git rev-parse` fails) - it exists
only as `gh-fork/wip/pg-v26-faultfix`, which explains earlier confusing local checks.

## But the PUBLISHED damage is exactly one PR

I enumerated every open PR's head branch and compared its `apps` pin:

    #1458  integ/pg-fork-zfs   <-- dangling pin, cannot `git submodule update`
    all 46 others              <-- valid or unaffected

And #1458 is the **explicitly DO-NOT-MERGE tracking branch**. So the publicly visible harm is
one PR that was never meant to merge.

## Decision: fix one branch deliberately, not 104 mechanically

Re-pinning 104 branches across three remotes is a large, risky, mostly-unobservable change,
and 103 of them are private working branches whose brokenness costs nobody anything today.
Directed instead:
1. Re-pin **`integ/pg-fork-zfs` only** to `b38b99cd` (the SHA the aarch64 lineage already
   blesses via osv commit `393903015`), G-signed, pushed - then **actually run a fresh
   `git clone --recurse-submodules`** of that branch and paste the result rather than assuming
   the pin resolves.
2. Note it in #1458's body so anyone who already hit the failure knows why.
3. **Report, not execute**, the commands for the rest, and identify which are branches we
   still actively use (`wip/pg-*`, `wip/aarch64-*`, `wip/fork-*`, `integ/*`) so I can fix
   roughly six deliberately rather than 104 mechanically.
4. Propose a cheap prophylactic. Root cause was `postgres18-musl/` staged-but-never-committed
   in my local `apps` tree, so the superproject recorded a SHA that was never created. A
   pre-push check that the recorded submodule SHA is reachable on a remote would have caught
   it.

## MY EARLIER FRAMING WAS TOO STRONG - corrected here so it stops propagating

I banked "every published benchmark is unreproducible". That is an overstatement. The accurate
version is **two distinct harms of different severity**:
- **Provenance**: x86 benchmark RESULTS measured on branches carrying the dangling pin cannot
  be rebuilt from the recorded tree. Real, and it is why result identity is now the triple
  (osv SHA, apps SHA, zfs banner).
- **Cloneability**: exactly **one** open PR (#1458) cannot be cloned with submodules.
Neither is "all 47 PRs are broken". I have overstated this once already; it is corrected in
place rather than left to be quoted later.

# Every published OSv/PG benchmark was unreproducible from the recorded tree

2026-09-07. Found by benchmark agent 0d31376d while cloning for a fresh run; confirmed
and root-caused by me. This is a process defect, and it is worth more than the run that
found it.

## The defect

`osv-1` (all the `wip/pg-*` benchmark branches, incl. `wip/pg-v26-faultfix` 73a332f26)
pins the `apps` submodule to `57c607984393901ce556a75f81ea40f7c469d1f3`.

**That SHA does not exist anywhere:**
- not in cloudius-systems/osv-apps
- not in gburd/osv-apps (GitHub API: 422 "No commit found")
- not on my private codeberg remote
- **not even in my own local `apps` checkout** (`git cat-file -t` fails locally)

Root cause: in my working `apps/` tree the entire `postgres18-musl/` directory was
**staged but never committed** (`git status` showed `A  postgres18-musl/...`). The
superproject therefore recorded a submodule SHA that was never created. `git submodule
update --init --recursive` can never succeed, for anyone, including me.

## Why it matters

The PostgreSQL application module IS the workload. So every OSv/PG number this project
has published - the 248k NOPM peak, the Firecracker 145k, the aarch64 correctness proof,
every tail-latency figure - **could not have been rebuilt by the maintainer, or by me
from a clean clone.** The measurements were real; their provenance was not recoverable.

This is the same class of failure as the earlier ones in this project (`ext_fsync ==
vop_nullop`, the swallowed `git apply` error): a silent gap that still stamps success.
Local state made it invisible because the files were present on disk.

## Resolution

Adopted the published tree `gburd/osv-apps wip/postgres18-musl-demo` @ **b38b99cd**
(2026-08-30, "postgres18-musl: -mno-outline-atomics on aarch64").

Verified my staged subset was **strictly worse**, so nothing unique was lost:

    my staged tree vs b38b99cd:  6 tracked files vs 9
      missing: fc-snapshot.sh, fc-snap.py, cpio_push.py
      build.sh: mine had ZERO occurrences of `outline-atomics`;
                b38b99cd has the fix at line 104

That aarch64 fix matters concretely: GCC 13 libgcc's LSE-atomics runtime init
(`lse-init.o`) references glibc's `__getauxval`, which musl does not export, so every
link fails and PG's configure cannot detect the GCC atomic builtins.
`-mno-outline-atomics` emits the atomics inline instead and links cleanly against musl.
So the published tree is the only one that can build PG for the aarch64 arm at all.

The old staged subset is preserved in an `apps` stash (not discarded):
`stash@{0} local postgres18-musl subset, superseded by b38b99cd`.

## Standing rule adopted

**A benchmark result's identity is the PAIR (osv SHA, apps SHA).** Both must appear in
every report header. A number attributable to only one of them is not attributable at
all. Both live campaign arms were instructed to report the pair, and to capture any
`build.sh` edits as a DIFF rather than fixing in place, so the reproducibility gap gets
closed properly rather than re-papered.

Still to do (deliberately deferred until the running builds finish, so the submodule
pointer does not change underneath them): commit the re-pin of `apps` to b38b99cd on the
benchmark branches and push, so a clean clone works.

## SCOPE CORRECTION (agent ff3a9ff1): the defect is x86-branch-specific

My "every published benchmark" framing was over-broad. Verified:

    wip/aarch64-forkcow-signed  ->  apps @ b38b99cd   OK, resolves
    wip/pg-v26-faultfix         ->  apps @ 57c60798   DANGLING

The aarch64 branch was **deliberately re-pinned** by osv commit `393903015` ("apps: bump
postgres18-musl to include -mno-outline-atomics aarch64 fix"), and its `git submodule
update --init --recursive` succeeds against the stock `.gitmodules` url.

So the fix already existed and simply **never propagated to the x86 lineage**. That is a
smaller and cleaner problem than I claimed: not a program-wide provenance collapse, but
one branch family left behind. Corrected here rather than left standing, since the
over-broad version would have been quoted later. The x86 arm's substitution to b38b99cd
is therefore not a workaround, it is adopting the SHA the aarch64 branch already blesses.

# SECOND DEFECT, worse: the module default puts PGDATA on RAMFS

Found by agent ff3a9ff1 BEFORE building, which is what saved the run. Confirmed by me in
`apps/postgres18-musl/module.py` lines 13-15:

    '--mount-fs=ramfs,/dev/null,/data '
    '/usr/bin/seed_copy /data-seed /data ; '
    '/usr/bin/postgres -D /data'

The default cmdline mounts a **writable ramfs at /data** and seeds it from a read-only
baked cluster. Benchmarking that measures a RAM filesystem, not ZFS-on-NVMe, and makes
`fsync=on` semantically vacuous: the numbers would look excellent and mean nothing, and
it directly violates the no-tmpfs requirement this campaign was commissioned under.

**Are the historical numbers affected?** I do not currently believe so. The tuning doc
records the override past runs used:

    zpool create ... -m /data pgdata /dev/vblkN
    initdb -D /data/base --waldir=/data/wal

i.e. ZFS mounted over /data, WAL on a separate dataset. So past runs overrode the
default. But the default is a live trap: any agent who did not check would have produced
confident, meaningless numbers. Both live arms are now required to prove the data path
with `SHOW data_directory`, `pg_relation_filepath`, `df`/`mount`, `zpool status`,
`zfs get`, and the exact boot command line - and to stop if anything under PGDATA or
pg_wal resolves to ramfs.

## Related trap chased at the same time: pool wipe between repeats

The tuning doc states `zpool create -f` in the boot chain **wipes /data on every boot**,
requiring a re-seed. If that happens between repeat runs, a 3-repeat median measures a
COLD database three times instead of a warmed steady state - the medians would not mean
what they appear to mean. Both arms asked to confirm the behaviour and state how dataset
persistence was preserved across repeats.

This is the third instance of the project's signature failure mode - a silent default or
gap that still stamps success (`ext_fsync == vop_nullop`; the swallowed `git apply`
error; now a RAM filesystem standing in for durable storage).
