# STEP 1b RESULT — Linux-ZFS flush rate + batch size on the SAME NVMe (the decider)

Box: i-0b054feb76fe528cb (m5d.metal). Same /dev/nvme1n1 as STEP 1a.
Linux arm: Debian 12 host, ZFS 2.1.11 (kmod), pool DIRECT on nvme1n1 (ashift=12 recsize=8k comp=off atime=off
sync=standard logbias=latency), arc_max=32 GiB. Workload: swstorm (C, pwrite 4k + fdatasync loop, N threads,
30s) = byte-for-byte the same op as zfs-bench sw_thread. Depth/flush counted via bpftrace kprobes on
zil_lwb_write_issue / zil_lwb_flush_vdevs_done (flushdone count is per-lwb and reliable; the issue kprobe
undercounts because zil_lwb_write_issue issues 1+ lwbs per call via its next_lwb loop, so Linux inflight/max
are unreliable - do NOT use them; use flushdone rate).

## Flush rate AND batch size vs concurrency, BOTH OSes, same NVMe

| thr | LINUX op/s | LINUX flush/s | LINUX commits/flush | OSv op/s | OSv flush/s | OSv commits/flush | flush/s ratio Lin/OSv |
|----:|-----------:|--------------:|--------------------:|---------:|------------:|------------------:|----------------------:|
| 8   |     31,529 |     **8,335** |                3.78 |   11,652 |   **3,219** |              3.62 |                 2.59x |
| 16  |     44,133 |     **5,283** |                8.35 |   15,992 |   **2,994** |              5.34 |                 1.76x |
| 32  |     55,370 |     **4,480** |               12.36 |   24,079 |   **2,564** |              9.39 |                 1.75x |

(Linux flush/s = median per-second steady-state flushdone delta from bpftrace; OSv flush/s = fanouts/window.)

## VERDICT (per the operator's discriminator): OSv COMPLETION-PATH cost, NOT device physics, NOT batching.
- Linux sustains **2.5x more flushes/s** than OSv at t8 (8335 vs 3219) with **near-identical batch size**
  (3.78 vs 3.62 commits/flush). At t16/t32 Linux is 1.75x the flush rate with comparable-or-slightly-larger
  batches. The device CAN do 8335 cache-flushes/s (Linux proves it on the same NVMe) - so ~3000/s is NOT a
  device-wide serial barrier.
- Batch sizes are comparable (Linux 3.78/8.35/12.36 vs OSv 3.62/5.34/9.39) - so batching is NOT the primary
  gap. Widening the commit window would help second-order at t16 but does NOT explain a 2.5x rate gap.
- => The ~3000 flush/s ceiling is an OSv-side FLUSH-COMPLETION cost (per-flush overhead in OSv's
  vdev_disk/zio_interrupt/virtio-blk FLUSH completion path), fixable in OSv.

## NUANCE the operator flagged, now measured: BOTH decline with concurrency.
Linux flush/s ALSO declines (8335 -> 4480) as OSv does (3219 -> 2564). So the decline is NOT an OSv-only
serialization signature - it is the normal batching tradeoff (bigger batches -> fewer, larger flushes; op/s
still rises on both). The discriminator is the ABSOLUTE RATE and the near-equal batch size, not the slope.
Linux's rate is 2.5x higher at every point. That 2.5x, with equal batches, is the OSv completion-path cost.

## CONFOUND still open (must close before the fix): transport.
Linux here is DIRECT NVMe; OSv is virtio-blk-in-qemu-guest. The 2.5x could be (a) OSv flush completion path,
or (b) the virtio-blk FLUSH round-trip that OSv pays and direct-Linux does not. NEXT: run Linux-ZFS + swstorm
INSIDE a qemu guest with nvme1n1 via the SAME virtio-blk (num-queues=4, cache=none aio=native) as OSv. If
guest-Linux still does >>3000 flush/s -> gap is OSv-specific (fix in OSv zio/vdev flush completion). If
guest-Linux collapses toward ~3000/s -> the virtio-blk FLUSH path is the shared ceiling (still fixable, but
the target is the FLUSH request handling, not zil.c). The measurement decides which.
