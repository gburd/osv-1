# Async write-completion bottleneck + the AioUringCompletion liveness wedge: root-cause brief

## THE TWO SYMPTOMS (both measured, both point at the same subsystem)
1. THROUGHPUT CEILING: with the footprint fix in, OSv PG-on-ZFS is FLAT across VU32-192 (151k/166k/153k/150k)
   at 0.42-0.73x Linux, sitting at only ~54-59% guest CPU with the NVMe pinned at 95-97% util, while Linux
   runs 84-88% CPU with the device under half utilized. OSv is NOT CPU-bound; it is stalled on the write path.
2. THE DECISIVE DISCRIMINATOR (removes durability, so it CANNOT be the commit/ZIL path):
   | arm                   | NOPM    | ratio | qemu-cpu   | nvme% | top waits                                  |
   | OSv   VU32 durable    | 142,163 | 0.49  | 1739 (54%) | 36.8  | LWLock/WALWrite 22.6%, AioUringCompletion 12.3% |
   | OSv   VU32 nondurable |  37,751 | 0.063 | 190 (6%)   | 0.44  | IO/DataFileWrite 50.7%, AioUringCompletion 22.9% |
   | Linux VU32 nondurable | 600,174 | 1.00  | 2727 (85%) | 36.9  | NONE/NULL 66.2% (CPU-bound, as expected)   |
   Dropping fsync WIDENED the gap (0.49x -> 0.063x): Linux doubles and CPU-saturates; OSv COLLAPSES to 6% CPU
   with an IDLE DEVICE. That is WAITING, not working. => the bottleneck is ASYNC WRITE COMPLETION
   (io_uring / ZFS writeback), NOT the ZIL/WAL commit path the campaign suspected for weeks.
   `LWLock/AioUringCompletion` is in the top-3 of BOTH OSv cells and NEITHER Linux cell.
3. THE LIVENESS WEDGE: 3 of 11 high-VU cells stopped progressing with 99.2-99.5% of time in
   AioUringCompletion, device IDLE, CPU IDLE, memory HEALTHY. Distinct from the (now-fixed) footprint OOM
   and from the old dentry deadlock. Same subsystem as (2), so very likely the same root or adjacent.

## SOURCE RECON ALREADY DONE (start here, do not re-derive)
core/io_uring.cc:
 - The WAITER blocks in `sched::thread::wait_for(ctx->mtx, ctx->wait_cq, tmr)` (lines ~832 and ~2139 in
   io_uring_wait_cqe). Completions post a CQE then call `ctx->wait_cq.wake_all(ctx->mtx)` (lines ~423, ~447,
   ~1423, ~1856).
 - CQE posting is `io_uring_post_cqe_locked()`: it flushes the overflow backlog, and if the CQ ring is FULL
   (or a backlog exists and ordering must hold) it pushes to `ctx->cq_overflow` (a std::deque) and sets the
   overflow flag (IORING_FEAT_NODROP - nothing is dropped, but the backlog is unbounded and drains only when
   the app frees slots). *** A CQ-ring-full + overflow-backlog regime is a prime suspect for BOTH symptoms:
   it serializes completions through a deque under ctx->mtx, and a mis-ordered flush/wake could strand a
   waiter that is waiting for a completion sitting in the backlog. ***
 - The WORK-QUEUE side uses `ctx->wq_wait[cls].wake_one(ctx->mtx)` (line ~1980) - a SINGLE-waiter wake on a
   shared work queue. Classic source of both throughput serialization (one worker woken per completion when
   several could run) and a lost-wake liveness bug at scale (wake_one racing an enqueue can leave work
   queued with every worker asleep). There are only 2 work-queue classes (index 0 = WQ_BOUNDED for
   file/disk ops that "complete promptly").
 - ctx->mtx is a single per-context mutex guarding the CQ, the overflow deque, pending_ops, and the wait
   queues. At VU192 with hundreds of backends this is a plausible serialization point on its own.

## THE INVESTIGATION (measure first; each hypothesis has a cheap discriminator)
H1 CQ-RING FULL / OVERFLOW BACKLOG. Instrument: count CQ-full events, cq_overflow depth (max + mean), how
   long entries sit in the backlog, and whether the overflow flag is ever set during a run. If the ring is
   chronically full at VU64+, completions are being funneled through the deque under a single mutex.
   Fix direction: a bigger CQ ring (is PG sizing it, or are we?), or drain/flush earlier, or avoid the
   backlog path entirely for the common case.
H2 WORKER WAKE STARVATION (wake_one on wq_wait). Instrument: worker thread count per class, how many are
   asleep while work is queued, and the wake pattern. If work sits queued while workers sleep, that is the
   liveness bug AND a throughput limiter. Fix direction: wake_all (or wake-N) when queue depth > 1, and
   close any wake_one-vs-enqueue race (the classic lost-wakeup shape).
H3 ctx->mtx CONTENTION. Instrument: hold time and waiters on ctx->mtx at VU64/128/192. If it is the
   serializer, per-queue or finer-grained locking is the direction. This would explain "device pinned at
   95% but CPU only 54%" if completions cannot be reaped fast enough to keep the pipeline full.
H4 WRITEBACK/PAGECACHE PATH (the nondurable collapse). The nondurable arm's top wait was IO/DataFileWrite
   50.7% with the device IDLE at 0.44% - so the writes were not even reaching the device. Something is
   throttling or stalling BEFORE the device: pagecache writeback (core/pagecache.cc writeback()/the periodic
   writeback thread), or the ZFS async write pipeline, or a dirty-data throttle with nothing draining it.
   *** The idle device with a 50% DataFileWrite wait is the strongest single clue in the whole dataset -
   chase it: who is supposed to drain dirty data, and is it running? ***
H5 THE WEDGE SPECIFICALLY. At the wedge, capture: are there queued-but-unreaped CQEs? is the overflow
   backlog non-empty? are all workers asleep with work queued? is a waiter blocked on wait_cq while its
   completion is already posted (the lost-wake signature)? Compare against a healthy cell's state. If a
   completion IS posted while a waiter sleeps, that is a lost wake and the fix is in the post/wake ordering.

## METHOD / DISCIPLINE (learned the hard way this campaign)
 - REPRODUCE the wedge first and get a deterministic-ish trigger (3/11 cells at high VU; find the knob).
 - CHECK the cheap confounds BEFORE concluding a wake bug: free memory + the console for OOM/panic (a
   reclaim stall LOOKS exactly like a lost wakeup), and the device/driver side.
 - A/B every lever with the RESOLVED value PRINTED and verified per arm (printf/debug_early, never debugf -
   it is verbose-gated). An A/B whose arms did not actually differ is worse than no A/B.
 - Prefer a discriminator that splits two hypotheses over an instrument that measures one.
 - The nondurable-vs-durable pair is already the highest-value discriminator in this dataset; keep using it.

## SUBSTRATE: hotdog (585335547908, us-east-2, --region explicit), quota 1152, keypair osv-hotdog, SG
## sg-0a0fec26afe57cd43 (ALREADY /32-scoped - USE AS-IS, NEVER 0.0.0.0/0, never widen), subnet us-east-2a
## subnet-04a66ccb68b2a2f13, Debian 12 ami-0dc1629a58a7d6458 (qemu 7.2.22, -M pc). Base
## gh-fork/bank/fork-footprint-reduction-signed @ 1480fbee1 (all fixes incl. the footprint fix), apps
## 3f93f43, bench-base-gate PASS. Raw NVMe passthrough. NEVER SIGKILL qemu mid-CHECKPOINT. hotdog is SHARED
## (solnix + others) - touch ONLY your own Owner=agent-* resources. Scaffolding: .local/scale, .local/gates,
## .local/cwwake, .local/footprint2 (boot/build/runcell/instr/quiesce/memprobe/churn all exist).

## DELIVERABLE: name the bottleneck mechanism with a discriminator (which of H1-H4, or something else), and
## name the wedge's root cause (H5). A fix + an A/B is the stretch; NAMING both with evidence is the
## minimum-viable. Any fix must be GENERIC (io_uring/ZFS/pagecache correctness or scalability), not
## PG-specific - PG is the forcing function only.

## *** CORRECTION (2026-09-20): THIS BRIEF'S CENTRAL PREMISE IS REFUTED. Read this before the above. ***
The agent demolished the framing with measurement AND PostgreSQL source. I was wrong in a specific way
worth recording: I MISREAD A WAIT-EVENT NAME AS A MECHANISM.

WHAT IS DEAD:
 - "ASYNC WRITE COMPLETION" DOES NOT EXIST IN PG18. pgaio_io_start_writev() has ZERO callers in the whole
   tree; ALL buffer/data-file writes go smgrwrite -> mdwritev -> FileWriteV -> pwritev, SYNCHRONOUSLY.
   io_uring is used for READS ONLY. So IO/DataFileWrite 50.7% with an idle device was NEVER an async
   completion stall - it is threads blocked in a SYNCHRONOUS pwritev. And LWLock/AioUringCompletion is PG's
   per-ring completion_lock in pgaio_uring_wait_one, reaping OTHER backends' READ completions: contention
   there is a symptom of READ waits, not of the write path. My H4/"async write completion" framing was a
   category error.
 - H1 (CQ-ring full -> cq_overflow deque) MEASURED DEAD: cqfull=0, ovf_cur=0, ovf_max=0 across 76 GB of
   writes / 70k CQEs at 442 live rings. The ring never filled; the deque I called "a prime suspect for BOTH
   symptoms" is never entered.
 - H2 (worker wake starvation via wq_wait wake_one) MEASURED DEAD: wq_starve=0, wq_qmax=12, wq_enq 70261 vs
   wq_wake1 70200, spawn 61. wake_one kept up.
 - The ZFS dirty-data throttle is also refuted: txdelay_calls=0, txdelay_sleeps=0, dirty_peak 492 MB vs
   dirty_max 3276 MB. Nobody is being throttled.

THE ACTUAL BOTTLENECK (measured at TWO independent layers): ZFS PHYSICAL WRITE AMPLIFICATION via vdev
AGGREGATION. OSv issues ~97-101 kB per device write vs Linux ~20-23 kB on the SAME pool geometry
(ashift=12, recordsize=8k) and same GUCs => ~4.8x amplification. In-ZFS probe: enq_wr_avg_kB=8 (PG's 8k
logical writes arrive CORRECTLY) but iss_avg_kB=146 and agg_avg_kB=653 - aggregation is inflating 8k
logical into ~146k average physical issues. THAT is why the NVMe pins at 95-97% while guest CPU idles at
54-59%: the device is doing ~5x the necessary work. The bottleneck is ZFS write inflation, NOT io_uring.
This explains the exact signature that puzzled us (device saturated + CPU idle), and the logical-vs-issued
gap is a DIRECT measurement of the inflation rather than an inference.

NEXT (steered): the zfs_vdev_aggregation_limit A/B, plus the why-does-OSv-differ-from-Linux question -
is OSv's aggregation behaving differently because of a missing/mis-set tunable default, or because the OSv
vdev layer advertises different device capabilities (max I/O size / queue depth) than the Linux vdev layer?
That distinction decides whether the fix is a DEFAULT or a VDEV-LAYER bug.

LESSON (standing): a wait-event NAME is not a mechanism. Before building a hypothesis on "the X path", CHECK
THAT PATH IS ACTUALLY EXERCISED by the workload (read the application's source for callers). I built five
hypotheses on a subsystem PG never uses for writes.
