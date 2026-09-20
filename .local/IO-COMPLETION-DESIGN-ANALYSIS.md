# OSv block-I/O completion + wakeup path: design analysis (traced, not guessed)

## The full ZFS durable-write completion chain (from source, base cbbf74e7)
    1. NVMe/virtio-blk MSI-X interrupt fires
    2. IRQ handler -> t->wake_with_irq_disabled()  wakes the SINGLE blk completion thread
       (drivers/virtio-blk.cc:179 - one thread services ALL virtqueues)
    3. blk::req_done wakes from wait_until(any_queue_not_empty), takes _queue_locks[q]
    4. drain_queue -> biodone(bio)               [fs/vfs/kern_physio.cc:74]
    5. biodone -> bio->bio_done(bio) = vdev_disk_bio_done   [INLINE - good, no hop here]
    6. vdev_disk_bio_done -> zio_interrupt(zio)   [modules/open_zfs patch 0001]
    7. zio_interrupt -> zio_taskq_dispatch(ZIO_TASKQ_INTERRUPT)   [zio.c:2085]
    8. -> spa_taskq_dispatch -> taskq_dispatch_ent(tq, ..., cutinline?TQ_FRONT:0)  [spa.c]
    9. OSv taskq_dispatch_ent -> taskqueue_enqueue -> wakeup(tq)   [SECOND thread hop]
   10. interrupt taskq thread runs zio_execute; zio pipeline advances
   11. zio_done -> cv_signal wakes the PG backend blocked in fdatasync   [THIRD thread hop]

## Where the ~0.44 ms/write (measured) plausibly lives
Three scheduler wakeups per durable write, each a potential cross-vCPU IPI round-trip on an
otherwise-idle system (idle = the waker and wakee are rarely already co-located; the scheduler must
send an IPI to wake a halted vCPU). ~0.15 ms/hop x 3 ~ 0.44 ms is the right order of magnitude.

Key structural facts:
- **Step 2-3: ONE completion thread for all virtqueues.** Fine at low IOPS; a serialization point at
  high concurrency, but the isolate is single-threaded so this is NOT the isolate's cost.
- **Step 7-9: the interrupt taskq hop is the prime suspect.** ZFS's WRITE row is
  { ZTI_SYNC, ZTI_N(5), ZTI_SCALE, ZTI_N(5) } (ISSUE, ISSUE_HIGH, INTERRUPT, INTERRUPT_HIGH). So a
  sync write's completion is dispatched to a 5-thread INTERRUPT taskq. `cutinline`/TQ_FRONT only jumps
  the queue - it does NOT run inline; it still wakes a taskq thread. On OSv, dispatching the completion
  to a separate taskq thread when the blk completion thread could advance the zio itself is a pure
  extra hop.
- The upstream comment at zio.c calls cutinline "cut the line" implying inline execution; on this SPL
  it is merely front-of-queue. That gap is the design lever.

## The candidate improvement (to VALIDATE, not yet implement)
Run the zio interrupt-stage completion INLINE on the blk completion thread when safe, instead of
dispatching to the INTERRUPT taskq - eliminating one full thread wakeup per completion. Upstream ZFS
already contemplates this (the cutinline path); OSv just needs cutinline to actually mean inline. This
is a generic OSv/SPL improvement (G2): every synchronous ZFS write benefits, not just PostgreSQL.

Risk to check: the blk completion thread must not block or recurse unboundedly if it runs zio_execute
inline (the existing comment at virtio-blk.cc:175-179 warns vdev_disk_bio_done "overruns" - read that).
Inline execution of a deep zio pipeline on the completion thread could stall other queues' draining.
So "inline when safe" needs a bound: run inline only the terminal interrupt stage, not an arbitrary
pipeline depth.

## MUST MEASURE FIRST (the campaign rule: reproduce the mechanism in isolation)
The syncwrite isolate (committed f45dac0db) with nofsync split, OSv vs Linux on matched ZFS-on-NVMe:
  - syncwrite (fsync each) p50/p99: quantifies the total per-durable-write tax.
  - nofsync p50/p99: write-completion cost WITHOUT the ZIL/flush stage.
  - The DIFFERENCE isolates the fsync/ZIL-completion hops from the plain-write hops.
Only after this decomposition do I know whether to attack (a) the interrupt-taskq hop, (b) the single
blk completion thread, or (c) the ZIL commit-completion cv_signal. Implementing before measuring would
be guessing - and two A/Bs already died as nulls from guessing the layer.

## Then, the loop
measure isolate -> identify dominant hop -> implement the minimal inline/wakeup change -> re-run
isolate (expect p50 drop) -> re-run HammerDB VU8/32/64 (expect NOPM lift + the null A/Bs explained) ->
qualify -> PR. The PR lands only when the isolate AND HammerDB both move, on a matched one-variable A/B.
