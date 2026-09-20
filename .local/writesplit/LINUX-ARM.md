# Linux-ZFS arm — per-lwb WRITE/FLUSH latency + in-flight depth (measured same way as OSv)

Box: i-029d704fc34d6a966 (m5d.metal, us-east-2, Debian 12 bookworm, kernel 6.1.0-53-cloud, qemu 7.2.22).
Arm: DIRECT-Linux on the metal host (not a guest) — the ZIL WRITE-vs-FLUSH latency is transport-agnostic at
the ZIL level, and direct-host avoids the no-udev zpool-create issue the prior run hit. ZFS 2.1.11-1+deb12u1
(DKMS), the SAME OpenZFS version the prior lwbpipe run's Linux arm used.
Device: /dev/nvme1n1 (instance-store NVMe, 838G) — the SAME physical NVMe the OSv arm uses (arms never concurrent).
Pool: ashift=12 recordsize=8k compression=off atime=off sync=standard logbias=latency (matched geometry).
Workload: syncwrite threads=N (each: 8k pwrite + fdatasync loop, distinct file, 30s). 8k matches recordsize.

Probes (bpftrace, paired on the lwb pointer; io_private @0x198 in struct zio, confirmed via objdump):
  WRITE latency = zil_lwb_write_issue(arg1=lwb) -> zil_lwb_write_done (WRITE_DONE)
  FLUSH latency = zil_lwb_write_done -> zil_lwb_flush_vdevs_done (FLUSH_DONE)
  in-flight gauge: ++ at zil_lwb_write_issue, -- at zil_lwb_flush_vdevs_done (IDENTICAL to OSv zw_inflight)

## RESULTS

| thr | op/s   | flush/s | WRITE avg | WRITE p50 | WRITE p99 | FLUSH avg | FLUSH p50 | FLUSH p99 | depth mean | depth max |
|----:|-------:|--------:|----------:|----------:|----------:|----------:|----------:|----------:|-----------:|----------:|
| 8   | 25,057 |   4,604 |   140 us  |   131 us  |   287 us  |    16 us  |    15 us  |    29 us  |    2.31    |     8     |
| 16  | 36,006 |   4,986 |   190 us  |   174 us  |   454 us  |    23 us  |    16 us  |  ~115 us  |    4.18    |    18     |
| 32  | 48,632 |   5,620 |   266 us  |   204 us  |  ~640 us  |    40 us  |    16 us  |  ~380 us  |   13.95    |    42     |

(flush/s = flush_count/30s. p99 at t32 from log2 hist bucket midpoints; write p99 in [512,1K), flush p99 in [256,512).)

## Two facts jump out immediately (compare to OSv RESULT.md STEP2d):
1. Linux FLUSH latency is ~16-40us avg (p50 ~15-16us). OSv FLUSH was ~110-123us. Linux flush is ~5-7x faster.
2. Linux in-flight DEPTH scales hard with concurrency: mean 2.3 -> 4.2 -> 14.0, max 8 -> 18 -> 42.
   OSv depth was mean ~1.4-1.5, max 6-11 and did NOT scale (stayed ~1.5 at all thread counts).
3. Linux WRITE avg 140/190/266us — OVERLAPS OSv's ~256-279us. At t8 Linux write (140us) is ~half OSv (256us);
   at t32 they converge (266 vs 279us) — but Linux is running at 14x the depth, so per-lwb write latency rises
   under its own much heavier pipeline while still delivering far more flushes/s.
