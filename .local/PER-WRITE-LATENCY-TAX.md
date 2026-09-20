# The bottleneck, refined to its sharpest form: a per-write OSv-side completion-latency tax

Two A/Bs (ZIL, dentry) both returned clean NULLs. The dentry run's histogram + OSv-side snapshot
localised the real cause, and it is NOT what I first guessed.

## What it is NOT (each ruled out by measurement, not argument)
- NOT the ZIL commit window (A/B null).
- NOT the dentry lock (A/B null; LWLock waits did not drop with per-chain locks: VU32 313->278,
  VU64 670->765 = noise).
- NOT PG lock contention (~88-90% of active backends in wait_event=NULL, LWLock tiny, Lock identical).
- NOT CPU-bound (qemu ~12-13% of 32 vCPU, HOST counter - the leg that makes it provable).
- NOT device-bound (NVMe ~13-17% util).
- NOT a dead-wakeup wedge: 0 of 62-64 backends frozen; they cycle rapidly through sub-5s states.

## What it IS
A **per-transaction OSv-side latency tax**: every syscall completion + scheduler round-trip costs more
than on Linux. Death by a thousand cuts, distributed across every backend, so no single wait event or
lock shows it and neither the CPU nor the device saturates.

## The cleanest isolate we have, and why it is decisive
The between-arm end-of-recovery checkpoint: **519.9s to write ~1M 8k buffers, write phase, fsync only
0.032s** => ~15 MB/s on an 85%-idle device, from ONE background process with NO concurrency.
  - One thread => NO lock contention is even possible. Rules out every concurrency explanation.
  - 15 MB/s of 8k = ~1920 writes/s = ~0.52 ms/write SERIAL. A real NVMe write is ~0.05-0.1 ms.
  - => OSv adds ~0.44 ms of pure completion/wakeup latency PER WRITE, single-threaded.
Linux pipelines writes (many in flight); if OSv serializes each on a full completion round-trip, that
is the entire per-transaction tax and it explains everything above.

## THE NEXT EXPERIMENT IS A MICROBENCH, NOT HAMMERDB
This is measurable in a 40-line loop without PostgreSQL - the winning method all campaign. And the tool
already exists: `scripts/bench/zfs-bench.c` has `wl_fsync` (write 4k + fsync in a loop, returns
fsyncs/s). What it lacks: per-op latency percentiles and a breakdown of WHERE the 0.44 ms goes.

Plan:
1. Enhance `wl_fsync` to record per-op latency (p50/p99) like wl_randwrite already does, and add a
   variant that does pwrite WITHOUT fsync (to separate write-completion cost from fsync cost).
2. Run it single-threaded on OSv-ZFS-on-NVMe and on Linux-ZFS-on-NVMe, matched (same instance, same
   pool geometry, same ashift/recordsize). ONE variable: the OS.
3. If OSv's single-thread write+fsync latency is ~0.44 ms above Linux's, the tax is CONFIRMED and
   isolated to the block-IO completion path (virtio-blk -> ZFS zio -> completion wakeup).
4. Then profile WHERE in that path: virtio-blk completion IRQ->thread wakeup latency, zio taskq
   dispatch, or the condvar signal that wakes the waiting writer. Each is a generic OSv fix (G2).

## Why this is the right target (G2, not a PG hack)
A per-write completion-latency tax hurts EVERY durable workload on OSv, not just PostgreSQL. Fixing the
block-IO completion/wakeup path is a generic platform improvement - exactly the deliverable ranked
above the application goal. PG was the forcing function that exposed it.

## Discipline this run honoured
- Predicted null (dentry) confirmed; combined with the histogram it RULES OUT the dentry lock rather
  than wasting the run.
- Leaned on the host CPU counter for "not CPU-bound," never the NULL wait event (60x trap avoided).
- VU64 stall captured as a datapoint, not fought. 0 orphans, 106 raw files archived (524 KB tgz).
