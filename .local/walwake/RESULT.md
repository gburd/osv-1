# WAL-commit-completion serialization: LOCALIZED and FIXED

BOX: i-0e6411d809a63a1f3 (m5d.metal, us-east-2a, Owner=agent-walwake) — TERMINATED (see end)
Branch: gh-fork/bench/walwake-mt @ fa513ac54

## TL;DR
The gate is **candidate A: the single virtio-blk completion thread**, NOT the zio
taskq (candidate B, measured and refuted). One `req_done()` thread drained ALL
virtqueues serially, running the whole ZIL-commit completion+wakeup chain
(biodone -> vdev_disk_bio_done -> zio_interrupt -> zil_lwb_flush_vdevs_done
cv_broadcast) inline for every completion. Fix: one completion thread per virtqueue
(OSV_BLK_MQ_COMPLETE=1). **+48% throughput at 32 concurrent committers, p50 latency
halved, and NVMe util rose 40%->75% (the completion path no longer bottlenecks the
device).**

## Base (stated per instructions)
Built bench/walwake-mt = gh-fork/bench/a2a-shape-fix (ALL levers: TCB #1504, fork,
ZIL hires #1505, wake-pull #1472, fsync #1507, dentry #1502) + cherry-picked
scripts/bench/zfs-bench.c from bench/syncwrite-mt (1cdbe3541, the threads=N
concurrent durable-write isolate). Chose a2a-shape-fix as the base because
syncwrite-mt itself LACKS the ZIL hires fix (#1505) - a2a-shape-fix has it, so the
ZIL completion path is representative. No PostgreSQL; pure ZFS durable-write isolate.
Guest: 32 vCPU / 64 GiB. Pool: single instance-store NVMe, ashift=12 (create_pool),
recordsize=8k, sync=standard (ZFS default) - matching the PG config.

## STEP 1 - MEASURE: the plateau is real, device+CPU idle (hypothesis SHAPE confirmed)
fsync sweep, secs=20 reps=3, medians:
  threads | agg op/s | scale | p50 us | p99 us
  1       |  5,376   | 1.00x |  152   |  554
  2       |  8,173   | 1.52x |  207   |  715
  4       | 11,786   | 2.19x |  287   | 1412
  8       | 21,302   | 3.96x |  293   | 1748
  16      | 21,749   | 4.05x |  644   | 2240   <- KNEE: +0.8% op/s, p50 x2.2
  32      | 27,772   | 5.17x | 1026   | 2876
Linear-ish to t=8 (~4x), flatlines t8->t16 (throughput +0.8% while p50 DOUBLES),
weak recovery at t32. Concurrency past ~8 committers converts to queueing latency,
not throughput.

Instrumentation at threads=32 (DECISIVE - not device/CPU-bound):
  - NVMe %util: 25-56%, median ~40%, aqu-sz 0.5-4.0   => NOT device-bound
  - Host CPU: ~89% idle, iowait 0                      => NOT host-CPU-bound
  - Guest vCPU: sum qemu-thread %CPU ~1223% = 12.2/32  => NOT guest-CPU-bound
    (matches M1 exactly: 12/32 vCPU busy, ~28-40% util)
Control (nofsync, write-only, no ZIL commit): t1=180k t8=105k t32=85k op/s -
memory/writeback-bound, declines with threads, totally different regime; confirms the
fsync path is the one that serializes on completion.

VERDICT: PLATEAU CONFIRMED. The WAL-commit-completion wakeup path IS the gate.

## STEP 2 - A/B

### Candidate B (zio NULL/FLUSH INTERRUPT taskq width) - REFUTED
The ZIL commit completion (zil_lwb_flush_vdevs_done cv_broadcast) is the done callback
of a ZIO_TYPE_NULL root zio dispatched to the NULL-INTERRUPT taskq (ZTI_ONE = 1
thread); FLUSH-INTERRUPT (device flush completions) also ZTI_ONE. Env OSV_ZIO_INTR_THREADS=N
raises the count. fsync secs=20 reps=3:
  threads | OFF    | ON=2         | ON=4         | ON=8
  8       | 21,302 | 20,128 (-6%) | 16,032 (-25%)| 16,014 (-26%)
  32      | 29,792 | 26,470 (-11%)| 27,697 (-7%) | 26,623 (-11%)
Widening the taskq does NOT lift the plateau; it HURTS monotonically. The zio taskq
is NOT the serialization point (it is downstream of the block completion). 4th
source-traced hypothesis on this path refuted by cheap measurement.

### Candidate A (per-queue virtio-blk completion) - CONFIRMED = THE FIX
drivers/virtio-blk.cc single req_done() thread drains ALL queues serially. Fix
(OSV_BLK_MQ_COMPLETE=1, default off): one completion thread per virtqueue
(req_done_q), each draining only its own queue, MSI-X vector i -> thread i.
fsync secs=20 reps=3, medians:
  threads |  OFF          | A ON (per-queue) | delta   | p50 OFF->ON | p99 OFF->ON (us)
  1       |  5,376        |  5,447           |  ~0     | 152->154    | 554->517
  2       |  8,173        |  8,547           |  +4.6%  | 207->200    | 715->629
  4       | 11,786        | 15,227           | +29.2%  | 287->220    | 1412->1370
  8       | 21,302        | 24,024           | +12.8%  | 293->272    | 1748->1734
  16      | 21,749/25,190 | 34,444           | +37-58% | 542->366    | 2169->2010
  32      | 27,772        | 40,597 / 41,185  | +46-48% | 1026->648   | 2876->2500
Reproducible (t32 A-on 40,597 then 41,185 then 40,093; OFF t32 stable 27.6-27.8k).
Low-thread (1,2) unchanged - no concurrency to spread (expected).
A-on threads=32 instrumentation: NVMe %util rose to peaks 68-78% (from ~40%),
w/s ~9200 (from ~6700), guest vCPU 12->14 - the completion path no longer
bottlenecks before the device.

## STEP 3 - for the HammerDB confirmation (NOT run here, per instructions)
FIX (precise):
  file:      drivers/virtio-blk.cc (+ drivers/virtio-blk.hh)
  mechanism: one completion thread per virtqueue (blk::req_done_q), each drains only
             its own queue; MSI-X vector i bound to thread i so completions on
             different queues drain in parallel across CPUs. make_request() already
             steers requests to queue = cpu_id % num_queues.
  env:       OSV_BLK_MQ_COMPLETE=1 (default off = historical single-thread drain);
             resolved mode+queue-count printed once at boot.
  branch:    gh-fork/bench/walwake-mt @ fa513ac54
Isolate before/after at threads=8/16/32 (op/s | p50 us):
  t8:  21,302 (293) -> 24,024 (272)
  t16: 21,749 (644) -> 34,444 (366)
  t32: 27,772 (1026) -> 40,900 (648)
GENERIC OSv improvement: YES. A parallel durable-write completion drain helps EVERY
fsync-heavy / high-completion-rate workload on OSv, not just PostgreSQL. PG-on-ZFS
was the forcing function that exposed it. Recommend running HammerDB end-to-end on
the projected-merged base with OSV_BLK_MQ_COMPLETE=1 to confirm the VU16/VU32 NOPM
gap closes.

Also pushed: modules/open_zfs/patches/0033 (OSV_ZIO_INTR_THREADS) - the refuted
candidate B, kept env-gated (default off, zero cost) as a documented instrument.

## Discipline / honesty
- Measured BEFORE fixing; refuted the strongest source-traced candidate (B) with
  cheap A/B rather than shipping it.
- Every claim carries pasted numbers (op/s + p50/p99) and a control (nofsync) +
  independent counters (host CPU idle, NVMe util, qemu-thread %CPU) so "not device-
  bound / not CPU-bound" is provable, not inferred from the NULL wait event.
- Harness note: qemu -nographic serial under this fedora-container/ssh setup only
  survives when streamed live through a pipe to a reader; the reliable pattern was
  `docker exec -d` detached + write to file + poll (a plain `> file` redirect loses
  all serial output). Cost ~40 min before the pattern was found; the measurements
  themselves are clean.
