# Clean-base determination: IN FLIGHT (agent 053e2e44)

Box: osv-cleanbase i-06bb64dc380d06365 @ 3.133.108.4 (bene, m5d.metal, KVM).
Agent terminates it when done.

## The one question
Does PostgreSQL run on **upstream/master + #1455 (fork)** alone, WITHOUT #1456
(per-child COW address space)?

That single answer picks the benchmark base for everything downstream (the p99
re-measurement, the aarch64 sweep, and any future performance claim).

## Why it matters
v26 is 24 commits behind master and missing two fixes that already invalidated
conclusions:
- `ae077860c` virtio-blk lock inversion: stalls I/O up to 19 SECONDS under
  sustained write load. Contaminated every p99 number.
- `af27ba4b7` libext real fsync: without it `ext_fsync` is `vop_nullop`.
Master has both, but master has NO fork() at all - and PostgreSQL needs fork.

## Verified topology going in
- #1455 (`wip/feat-fork`) merges CLEAN onto master (merge-tree exit 0), brings
  `libc/process/fork.cc`.
- #1456 (`wip/fork-stage2-pr`) does NOT stack: 10 conflicted files, add/add on
  `libc/process/fork.cc`, `arch/*/fork.cc`, `include/osv/fork.hh` - so #1456 is a
  REVISED VERSION of the same feature, not an increment.

## The escalating test (how far does base A get?)
1. PG reaches "ready to accept connections"?
2. single client `select version()` works?
3. 32 concurrent backends (`pgbench -c 32 -j 32`) - THIS is what #1456's
   per-child COW may be load-bearing for
4. short HammerDB TPROC-C at VU32 to prove multi-VU

A crash at step 3 or 4 is the evidence that #1456 is required, and is a perfectly
good answer.

## Fallback if base A fails at concurrency
base B = v26 with current master merged IN (not rebased), to get `ae077860c` into
a measured tree while accepting messier history. Agent reports conflicts resolved
and whether PG serves.

## Expected byproduct
Whether the MKBOOTFS gap (PR #1494, pending) still bites on master's newer
open_zfs in-tree layout.
