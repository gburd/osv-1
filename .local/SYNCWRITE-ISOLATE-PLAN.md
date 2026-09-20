# The syncwrite isolate: ready-to-run instrument for the per-write latency tax

Committed `f45dac0db` on wip/pg-rx-directwake (a stale WIP branch - move it to a clean branch before
filing anything; it is bench tooling, not yet a PR). Adds `syncwrite` to scripts/bench/zfs-bench.c:
single-thread 8k pwrite + fdatasync loop with per-op p50/p99, and `nofsync=1` to split write cost from
durability cost.

## Validated locally (tmpfs, just proving the loop + percentiles work)
    fsync-each   1,238 op/s   p50=692us  p99=2604us
    nofsync    353,417 op/s   p50=2.2us  p99=7.4us
285x gap on tmpfs alone - the harness clearly resolves the fsync cost. Real signal will come from
OSv-vs-Linux ZFS-on-NVMe.

## The experiment (ONE variable: the OS)
Same instance class, same NVMe, same pool geometry (ashift=12, recordsize=8k, compression=off,
sync=standard), same 8k block size. Run on:
  A. OSv guest, ZFS-on-NVMe, /zfs-bench.so syncwrite + syncwrite nofsync=1
  B. Linux, same ZFS-on-NVMe, a host build of the same zfs-bench.c syncwrite + nofsync=1
Compare p50/p99 per op. Predictions from the checkpoint isolate (0.44ms OSv overhead/write):
  - syncwrite (fsync each): OSv p50 ~0.5ms vs Linux ~0.1ms  => the tax is CONFIRMED and isolated
    to the durable-write completion path.
  - nofsync (write only):  if OSv is ALSO slower here, the cost is in write/zio completion, not fsync;
    if OSv matches Linux here, the cost is specifically in the ZIL/flush completion wakeup.
This DECOMPOSES the tax: write-completion vs durability-completion. That is the fork in the road for
the fix, and it is a 2-minute run per arm, not an 8-hour HammerDB sweep.

## Then: profile WHERE the winning arm spends the 0.44ms
Candidates in the OSv block-IO completion path, each a generic G2 fix:
  1. virtio-blk completion IRQ -> waking thread latency (the completion thread was idle in the wedge bt).
  2. ZFS zio taskq dispatch round-trips (a write threads through multiple taskq stages).
  3. the condvar signal that wakes the blocked writer (cv_signal one-at-a-time vs broadcast).
The syncwrite isolate + an OSv thread/backtrace sample under it will point at one.

## Why this supersedes more HammerDB
HammerDB proved the SHAPE (declines) and localised the LAYER (OSv-side, per-write, not lock/CPU/device).
Further HammerDB sweeps would re-confirm that at $9/hr. The isolate measures the actual mechanism for
cents and gives a number to optimise against directly. Only return to HammerDB to confirm a fix moves
NOPM end-to-end.

## Housekeeping note
zfs-bench.so must stay pure C (a g++ .so fails to load: GLIBCXX/CXXABI undefined). The syncwrite
addition is pure C - verified it compiles with -std=gnu11 -D_GNU_SOURCE, no C++.
