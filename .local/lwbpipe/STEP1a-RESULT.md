# STEP 1a RESULT — LWB in-flight depth on OSv (DIRECT measurement)

Box: i-0b054feb76fe528cb (m5d.metal, Debian 12 bookworm, kernel 6.1.0-53, qemu 7.2.22 native -M pc, KVM).
OSv build: gh-fork/bench/lwbpipe @ 8065242fc (m1-confirm base + zilwake probe #0034 + depth gauge #0035).
Patch verified IN BUILT SOURCE: ZILDEPTH_IN_SRC=1, zw_depth_accum x3, zw_inflight x9, OSV_ZIL_WAKE_UNLOCKED x3.
Device: /dev/nvme1n1 (instance-store NVMe, 838G) as virtio-blk vblk1, num-queues=4, cache=none aio=native.
Guest: 32 vCPU / 64 GiB. Pool ashift=12 recordsize=8k compression=off atime=off sync=standard (default) logbias=latency.
Workload: zfs-bench syncwrite threads=N (each: pwrite 4k + fdatasync loop, distinct file, 30s). Baseline (WAKE_UNLOCKED off).

## The numbers (window=30s for t16/t32; t8 from a 20s smoke, same shape)

| threads | op/s   | flush/s | infl_max | MEAN depth | issue_gap_us | mean_N (batch) | p50 us | p99 us |
|--------:|-------:|--------:|---------:|-----------:|-------------:|---------------:|-------:|-------:|
| 8       | 11,652 |   3,219 |    **6** |   **1.44** |        310.2 |           3.62 |  588   | 2134   |
| 16      | 15,992 |   2,994 |    **8** |   **1.80** |        333.2 |           5.34 |  788   | 3272   |
| 32      | 24,079 |   2,564 |   **11** |   **1.52** |        387.7 |           9.39 | 1090   | 5222   |

(mean depth = depth_integral_ns / window_ns; flush/s = fanouts / window.)

## VERDICT: the strict "depth ~1" hypothesis is REFUTED — but the reframe holds.
1. Depth is NOT pinned at 1. Max in-flight lwbs = 6/8/11 (grows with concurrency), MEAN in-flight = ~1.4-1.8.
   Flushes DO overlap; the upstream parent-child pipeline IS working on OSv. So the fix is NOT "enable
   concurrent flushes" — they are already concurrent (up to 11 at once).
2. The ~3000 flushes/s "pin" is REAL and even DECLINES with concurrency (3219 -> 2994 -> 2564/s). Throughput
   grows (11.6k -> 24k op/s, ~2x for 4x threads) purely by BATCH SIZE (mean_N 3.6 -> 9.4), never by flush rate.
3. The issuer's mean inter-issue gap (~310-388us) tracks the flush latency (~333us) and RISES with load. So on
   AVERAGE the issuer advances at ~one-flush-latency cadence (mean depth ~1.5), even though bursts reach 11.

## What this means for the fix (pending STEP 1b)
The bottleneck is the ~3000 flushes/s CEILING, not a literal depth-1 pipeline. The decisive question is now
1b: is ~3000 flushes/s a device-wide serial cache-flush barrier (NVMe physics, seen on Linux too -> fix =
BATCHING), or does Linux-ZFS on the SAME device sustain many-thousands of flushes/s (-> OSv-side flush-path
cost/serialization -> fix = make each flush cheaper / raise the achievable rate)?  Do NOT pick a fix until 1b.
