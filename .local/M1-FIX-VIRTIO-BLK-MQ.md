# M1 fix: virtio-blk per-queue completion. Localized, corrected, filed as #1509.

## The gate, localized by measurement (agent af386ad6)
The concurrent syncwrite isolate (threads=1..32) on OSv ZFS-on-NVMe showed the plateau is real:
    threads   8 -> 21,302 op/s   16 -> 21,749 (FLATLINES, +0.8%)   32 -> 27,772
    at threads=32: NVMe 40% util, host 89% idle, 12.2/32 vCPU busy -> matches M1 exactly
Not device-bound, not CPU-bound. Completion serialization.

## Two candidates discriminated (measure, don't assume)
- Candidate B (zio INTERRUPT taskq width, OSV_ZIO_INTR_THREADS): REFUTED - widening it HURT -26%.
  The zio taskq is downstream of the block completion, not the gate. My strongest source-traced guess,
  wrong again, caught by measurement.
- Candidate A (single virtio-blk completion thread): CONFIRMED. One req_done() thread drained ALL
  queues serially, running biodone->zio_interrupt->zil_lwb_flush_vdevs_done cv_broadcast inline per
  completion. Per-queue completion threads:
    threads   8 -> +13%   16 -> +58%   32 -> +48%   p50 1026->648us   NVMe util 40->75%

## The deadlock I caught and corrected before filing
The agent's req_done_q took WITH_LOCK(_queue_locks[qid]) during drain. But make_request holds that
lock across a SLEEPING add_buf_wait() when the ring is full -> a completion thread taking it deadlocks
against the producer waiting on that thread to free ring space (the exact 1-in-3 hang the original
single-thread req_done documented and avoided). The benchmark did not hit it (ring never filled), but a
real ZFS checkpoint burst would. FIXED: req_done_q drains lock-free (single-consumer per queue, races
the producer only on the u16 used-ring head), matching the original invariant. Commit message + a code
comment document why.

## Filed: PR #1509 (master-facing, self-contained)
gburd:pr/virtio-blk-mq-complete, OPEN, MERGEABLE, merge-tree clean, G-signed d121c8f76. Only touches
drivers/virtio-blk.{cc,hh}. Dropped the bench-only patch 0033 (refuted taskq knob) from the PR.
Default OFF (single-queue guests unaffected; costs one thread per queue), enabled per boot; the strong
measured evidence is in the body for the maintainer to decide on default-on. Generic: helps every
fsync-heavy multiqueue-virtio-blk workload, PG the forcing function.

## STILL REQUIRED before claiming M1 progress: HammerDB end-to-end confirmation
The fix moved the ISOLATE (+58% aggregate durable-write throughput). The M1 claim requires it moving
NOPM on the projected-merged base, matched OSv-vs-Linux. Prediction: OSv VU16 stops declining (the
completion serialization was why it fell 104k->65k); how close to Linux 269k it gets is the open number.
Run: projected-merged base + #1509 (OSV_BLK_MQ_COMPLETE=1), VU8/16/32/64, matched Linux (32 GiB ARC),
via build-projected-base.sh --manifest M (plan, then --apply) and bench-preflight.sh (usage in AGENTS.md).
This is the next benchmark and the real M1 verdict.

## Session PR tally (M1 arc)
#1502 AB-BA (proven e2e) | #1505 ZIL hires | #1506 ARC-max | #1507 fsync scan | #1508 physio per-iovec |
#1509 virtio-blk per-queue completion | #1472 wake-pull default-on. All master-facing, generic (G2).
