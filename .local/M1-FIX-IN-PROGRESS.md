# M1 fix: localizing the WAL-commit-completion serialization (agent af386ad6)

## The lever (from the matched M1 result)
OSv does not scale where Linux does because backends block waiting to be WOKEN after their fdatasync/ZIL
commit completes. NULL-wait 68%, device 28%, 12/32 vCPU at VU16. The completion chain:
  fdatasync -> zil_commit -> LWB write + device FLUSH -> SINGLE virtio-blk req_done thread -> biodone
  -> vdev_disk_bio_done -> zio_interrupt -> zio INTERRUPT taskq -> zil_lwb_flush_vdevs_done
  -> cv_broadcast each waiter -> woken backends scheduled onto vCPUs

## Three candidate serialization points (to be DISCRIMINATED by measurement, not assumed)
  A. the single virtio-blk completion thread (one thread drains all queues serially)
  B. the zio INTERRUPT taskq thread count (cv_broadcast fan-out serialized)
  C. scheduling of woken backends (likely NOT it - WAKE_PULL on, wedge showed 0 runnable)

## The instrument (built, pushed): bench/syncwrite-mt (1cdbe3541)
zfs-bench `syncwrite threads=N` - N concurrent 8k pwrite+fdatasync writers, aggregate op/s + pooled
p50/p99, nofsync=1 control. Validated locally (scales on tmpfs). On master, merge-tree clean.
DISCRIMINATOR: run threads=1..32 on OSv ZFS-NVMe. If aggregate op/s PLATEAUS while device+CPU idle ->
completion path is the gate (expected). If it SCALES -> hypothesis refuted, gap is elsewhere.

## The discipline (why measure first)
Three prior hypotheses on THIS path were refuted by cheap measurement (inline-interrupt-stage,
honoured-batch-window, device-flush). Building a fix before the isolate localizes the hop = the exact
trap. Agent af386ad6: STEP 1 measure (threads sweep + %util + vCPU-busy), STEP 2 A/B the candidate the
measurement points to (env-gated: raise zio INTERRUPT taskq threads, or parallelize blk completion),
STEP 3 report before/after for a separate HammerDB confirmation.

## Fix candidates prepared (to try in measurement-pointed order)
1. Raise zio INTERRUPT/FLUSH taskq thread count (candidate B) - smallest change, env-gated.
2. Per-queue virtio-blk completion (candidate A) - bigger, only if B does not move it.
Both env-gated for same-image A/B, default off, resolved-value printed once.

## Success criterion
The fix is validated only if aggregate syncwrite op/s at threads=32 rises materially with it on, on a
same-image A/B. Then HammerDB confirmation on the projected-merged base. Generic OSv win (faster durable
-write completion helps every fsync-heavy workload), PG as forcing function - the right G2 shape.
