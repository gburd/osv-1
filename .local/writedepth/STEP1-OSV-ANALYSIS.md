# STEP 1 discriminator - OSv results (m5d.metal i-0179b5abdcea6333b, raw /dev/nvme0n1 passthrough)

qemu 7.2.22 Debian, guest 32 vCPU / 32G, num-queues=8, MQ_COMPLETE=1 (#1509 default-on),
all other levers OFF. 3 reps x 30s. RESULT lines median.

## The discriminator table (OSv)
| thr | SVC device us (mean/max) | wrlat ISSUED->WRITE_DONE us | queue-wait = wrlat-SVC | vqwrite depth mean/max | lwb depth mean* | zp_open/prevnf/decay | op/s |
|-----|------|------|------|------|------|------|------|
|  8  | 189.9 / 197138 | 276.7 | ~87  | 0.88 / 6  | ~1.35 | 473k/230k/56k (7.4% decay) | 11999 |
| 16  | 201.5 / 225288 | 301.3 | ~100 | 0.94 / 7  | ~1.68 | 512k/303k/8.8k (1.1% decay) | 18872 |
| 32  | 199.4 / 178959 | 288.0 | ~89  | 0.92 / 10 | ~1.40 | 450k/273k/5.9k (1.0% decay) | 31846 |

*lwb depth mean = depth_integral_ns / (run wall time). At t32: 133.9e9 ns integral over ~90s wall (3x30) ~= 1.5.
 The ZILDEPTH inflight_max (7/11/17) is the lwb pipeline peak; the vdev-queue write depth (vqwrite) is <1 mean.

## What the OSv data ALONE already shows (before Linux):
1. **The device SERVICE time is FLAT ~190-200us regardless of thread count.** It does NOT rise with
   concurrency -> the device is not saturated; we are feeding it ~one write at a time.
2. **wrlat (ISSUED->WRITE_DONE) = 277-301us = SVC(~195) + ~90-100us of NON-device time.** So the earlier
   "288-372us write" was ~1/3 queue/pipeline overhead on top of the ~195us device service. The device
   write itself is ~195us, not ~300us.
3. **vqwrite_depth_mean < 1.0** at every thread count, max only 6-10. We NEVER approach the
   sync_write_max_active=10 cap in the mean; the vdev queue almost never has >1 sync-write zio active.
   -> The throttle is NOT the vdev-queue cap. It is upstream: writes arrive at the queue ~one at a time.
4. **zl_parallel is NOT decaying** (decay 1-7%): the batching logic latches to aggregate ~93-99% of the
   time. So "zl_parallel decays under OSv fast completion" (a candidate hypothesis) is REFUTED - the
   issuer intends to aggregate. Yet depth stays ~1. The batch window sleep is tiny (mean 41-48us) and
   waiters mostly TIME OUT (waiter_timedout ~= sleeps), i.e. each commit waits its ~45us window, times
   out, and issues its own lwb -> lwbs are issued back-to-back but each completes (~195us SVC + flush)
   before the next few can overlap, because the arrival cadence x round-trip keeps overlap ~1.

## The pending discriminator: is OSv's ~195us device SERVICE ~= Linux, or 2x?
IF Linux device SERVICE (same /dev/nvme0n1, bpftrace) ~= 195us -> the write is NOT slower; the gap is
  the low overlap (depth ~1). Fix = raise write-issue overlap/cadence.
IF Linux device SERVICE ~= 100us (2x faster) -> OSv's virtio-blk write round-trip is genuinely slower.
  Fix = the write path (virtio submit->completion, abd copy).
Measured next: Linux guest, same passthrough device, bpftrace the nvme/bio write service time + a
depth gauge, t8/16/32.
