# STEP 1 DISCRIMINATOR - VERDICT (matched OSv vs Linux, SAME m5d.metal, SAME raw /dev/nvme0n1)

Box i-0179b5abdcea6333b, qemu 7.2.22, Debian 12. OSv: guest 32vCPU/32G, virtio-blk num-queues=8,
MQ_COMPLETE=1, all other levers off. Linux: DIRECT on host, ZFS 2.1.11 DKMS, matched pool
(ashift=12 recsize=8k comp=off sync=standard logbias=latency), same syncwrite (8k pwrite+fdatasync),
3x30s. Depth gauges IDENTICAL (++ at lwb write_issue, -- at flush_vdevs_done). SERVICE = device
submit->completion (OSv zio->io_delay aggregated in vdev_queue_io_done for SYNC_WRITE; Linux
block_rq_issue->block_rq_complete for nr_sector>0 writes on the pool nvme).

## THE TABLE
| thr | OSv SVC | Linux SVC | SVC ratio | OSv wrlat | Linux wrlat | OSv lwb-depth mean/max | Linux lwb-depth mean/max | OSv op/s | Linux op/s | op/s ratio |
|-----|---------|-----------|-----------|-----------|-------------|------------------------|--------------------------|----------|------------|------------|
|  8  | 189.9us | 100.5us   | 1.89x     | 276.7us   | 150.4us     | ~1.4 / 6               | 2.37 / 13                | 11999    | ~25000     | 0.48x |
| 16  | 201.5us | 128.2us   | 1.57x     | 301.3us   | 196.3us     | ~1.7 / 7               | 12.21 / 38               | 18872    | ~34500     | 0.55x |
| 32  | 199.4us | 167.7us   | 1.19x     | 288.0us   | 270.4us     | ~1.4 / 10              | 12.94 / 41               | 31846    | ~45700     | 0.70x |

(OSv vqwrite_depth_mean < 1.0 at all thr, max 6-10: the vdev queue almost never has >1 sync-write zio
 active - so the sync_write_max_active=10 cap is NEVER the throttle. zl_parallel decay only 1-7%: the
 issuer INTENDS to aggregate. waiter_timedout ~= sleeps: each commit waits its ~45us window then issues.)

## VERDICT: it is BOTH, but DEPTH is the dominant and thread-scaling one. Precisely:

### (1) OSv device SERVICE IS genuinely slower - but the ratio SHRINKS with concurrency (1.89x -> 1.19x).
OSv device write service is ~190-200us and FLAT. Linux is 100-168us and RISES with thread count.
- OSv flat ~195us = the virtio-blk write round-trip at depth ~1 (submit -> host aio_native -> device ->
  MSI-X -> completion). This is real OSv-side write-path cost: ~90us over Linux at low concurrency.
- Linux service RISES 100->168us precisely BECAUSE it drives 12-14 writes concurrently: the device
  queue deepens, so each individual write's service time grows (queuing at the device). By t32 the two
  nearly converge (199 vs 168) - Linux "pays back" its low-concurrency latency advantage as it loads
  the device. This is Little's law: Linux trades per-op latency for throughput via DEPTH.

### (2) The DEPTH gap is the dominant lever and it does NOT self-resolve.
OSv lwb-depth mean is ~1.4-1.7 and FLAT across 8/16/32 threads. Linux is 2.4 -> 12.2 -> 12.9 - it
pipelines ~9x deeper at t16/t32. Rate = depth / round-trip. Even at OSv's own ~195us service, depth
2 -> 10 would ~5x the issue rate. THIS is why op/s stays ~0.5x: OSv feeds the device one write at a
time while Linux keeps ~13 outstanding.

### Why does OSv keep only ~1.4 in flight when zl_parallel does NOT decay and the queue cap is 10?
The batching logic latches to aggregate (zp_decay 1-7%), the vdev queue cap (10) is never hit
(vqwrite mean <1), and the commit-waiter window is tiny (~45us) so waiters TIME OUT and each issues its
own lwb. So lwbs ARE issued back-to-back by many threads - but each lwb's whole round-trip (write ~195us
SVC + flush) completes before enough successors overlap, so the STEADY-STATE overlap sits at ~1.4.
On Linux the same logic reaches steady-state overlap ~13. The difference is NOT the ZFS governor (proven
identical: cap not hit, parallel not decayed) - it is that OSv's issuer/commit cadence does not launch
successor lwbs fast enough relative to completion to build a deep pipeline. i.e. the OSv side completes
-> re-issues one-at-a-time rather than having many concurrently outstanding.

## THE FIX THE DISCRIMINATOR NAMES: raise write-issue DEPTH (cheaper, thread-scaling, the dominant gap).
Not the write path (its ratio shrinks to 1.19x by t32 and is a fixed ~90us floor). DEPTH is 9x and flat.
The lever: keep more lwb writes outstanding - drive the commit-writer to issue successor lwbs while prior
ones are still in flight, instead of the current ~1-at-a-time cadence. Candidate mechanisms to A/B in
STEP 2 (measure which raises lwb-depth-mean toward ~10):
  (i)  do NOT let the commit waiter time out into single-lwb issue so eagerly - widen the aggregation so
       a batch of itxs rides ONE larger lwb (fewer, deeper) OR conversely
  (ii) actively re-enter/re-run the issuer to launch the next lwb batch while prior lwbs are ISSUED
       (the pipeline-fill), rather than each backend synchronously issuing then waiting.
The env-gated fix + isolate A/B is STEP 2/3.
