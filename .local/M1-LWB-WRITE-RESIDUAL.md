# M1: root cause of the flush-rate gap LOCALIZED to the ZIL block-WRITE. #1509 default-on shipped.

## What the run PROVED (all measured, refutations by data)
- depth-1 REFUTED: OSv keeps 6-14 lwbs in flight (mean ~1.5), pipeline works.
- device-physics + batching REFUTED: Linux does 7077 flush/s at t8 with IDENTICAL batch (3.78 vs 3.62)
  on the SAME NVMe. OSv's ~3000/s is an OSv-side cost.
- issuer-pacing / commit-window REFUTED: waiter wakes ~60us, serial issue ~14us, widening the window
  HURTS (-53% at pct=100). None is the cost.
- ROOT CAUSE localized: the ~380us per-lwb latency is 70% ZIL block-WRITE (~270us), 30% FLUSH (~110us,
  healthy). The write splits into: virtio-blk WRITE bio round-trip 145-211us (2-3x the FLUSH on the SAME
  transport!) + OSv zio pipeline ~90-120us (incl a synchronous abd_borrow_buf_copy).
- The sharpest clue: a PLAIN 8k pwrite completes in ~6us on this device; the lwb sync-WRITE takes
  ~270us. The ~264us delta is OSv-side ZIL-write-path overhead (zio stages + abd copy + a write bio
  that is 2-3x a flush), NOT the device.

## SHIPPED (confirmed, master-facing): #1509 virtio-blk per-queue completion DEFAULT-ON (c4ce6d0c2)
Matched isolate A/B: +33-38% op/s, +40-43% flush/s at t16/t32, p99 halved (5828->2593us). Env off-switch
OSV_BLK_MQ_COMPLETE=0 preserved. This is the single biggest M1 lever found and it is now the stock
behaviour. Narrows OSv/Linux from ~0.40x to ~0.58x on the isolate. HONEST: does NOT close the gap and
was a HammerDB-null earlier (TPROC-C at 200wh does not saturate the completion path); it is a real
durable-write-path win, not an M1-parity claim.

## THE NAMED RESIDUAL (follow-up run - localized, not fixed)
The ~270us ZIL block-WRITE. Two sub-targets, both measured:
  1. **abd_borrow_buf_copy** - a synchronous data copy in the OSv zio write path (~part of the 90-120us
     pipeline overhead). Is it avoidable / can the lwb write go zero-copy?
  2. **the write bio round-trip is 145-211us = 2-3x the FLUSH (110us) on the SAME transport, while a
     plain pwrite is 6us.** WHY is the ZIL write bio so much slower than a plain write bio? Prime
     suspect: the ZIL write is a SYNC/durable write (O_DSYNC-equivalent at the zio level) that may be
     issued with a per-bio barrier/FUA or routed through a slower path than plain async writes. Linux
     ZIL writes may not force per-write durability the same way (they rely on the trailing flush).
     THIS is the likeliest big lever: if OSv makes every ZIL block-write individually durable (write+
     implicit-sync) instead of write-then-one-flush, that doubles the round-trip. Check vdev_disk /
     virtio-blk: does the lwb write bio carry a sync/FUA flag or go through zio_flush-per-write?

## NEXT EXPERIMENT
Trace the lwb write bio flags/path vs a plain write bio on OSv. If the ZIL write is FUA/sync-flagged or
double-syncing, remove that (ZIL correctness needs write-then-flush, NOT per-write-sync-then-flush).
Then re-measure the isolate (write latency should drop ~2x -> flush rate ~double -> toward Linux) AND
run HammerDB to see if it moves TPROC-C NOPM (the true M1 verdict - the write-rate lever may transfer
to TPROC-C where the completion-path lever did not, because WAL commits ARE durable writes).

## M1 PR ledger (all master-facing, generic G2)
#1502 AB-BA | #1505 ZIL hires | #1506 ARC-max | #1507 fsync scan | #1508 physio | #1509 per-queue
completion DEFAULT-ON (measured +33-38%) | #1472 wake-pull default-on | #1510 ext4 (draft) |
Lever-1 zil-wake-unlocked (contention). Next: the ~270us ZIL-write residual (abd copy + sync/FUA write).
