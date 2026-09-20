# STEP 2d — the batching window is NOT the fix; the LWB WRITE latency (~270us) is the real cost

Build gh-fork/bench/lwbpipe @ 7e297fbc2 (+ probe 0039). MQ_COMPLETE=1. Verified in built source.

## Commit-window A/B (OSV_ZIL_COMMIT_TIMEOUT_PCT; 10 = compiled default):
| pct | t8 op/s | t8 p99 | t32 op/s | t32 p99 |
|----:|--------:|-------:|---------:|--------:|
| 10  |  13,295 | 1832us |   34,174 | 2793us  |
| 30  |  12,083 | 1735us |   34,607 | 2741us  |
| 50  |   9,980 | 1852us |   32,944 | 2861us  |
| 100 |   6,237 | 2327us |   23,970 | 3491us  |

### VERDICT: widening the commit window HURTS (t8 monotonic -53% at pct=100) or is flat/negative (t32 peak at
pct=30 +1.3% then declines). BATCHING is NOT the fix - refuted. A bigger window makes each waiter wait longer,
in-flight depth DROPS (t8: 6->4->3->3), throughput falls. OSv is already aggregating as much as helps; forcing
more just adds latency. So neither pipelining (depth already overlaps) NOR batching (window) is the lever.

## THE REAL COST, finally localized: the LWB WRITE latency, not the flush.
ZILFLUSHLAT split of the ~380us whole-lwb latency (issue -> FLUSH_DONE):
  t8  pct10:  write (issue->WRITE_DONE) = 256 us   flush (WRITE_DONE->FLUSH_DONE) = 123 us
  t32 pct10:  write                     = 279 us   flush                          = 110 us
=> The WRITE portion (~256-279us) is ~70% of the lwb latency. The FLUSH is only ~110-123us (fast, ~ what a
local NVMe cache-flush should be). So the ~2x rate gap vs Linux is NOT the flush/transport and NOT batching -
it is the ZIL BLOCK WRITE itself taking ~270us on OSv.

## Why this closes the diagnosis (Little's law, self-consistent):
mean depth ~1.4-1.5, whole lwb latency ~380us -> flush rate = depth/latency = ~3700-3900/s -> op/s = rate x
batch. Since depth is bounded (~1.4) and the WRITE dominates the latency, cutting the ~270us write latency is
the only lever that raises the rate. The write is a ZIO_PRIORITY_SYNC_WRITE zio_rewrite of the lwb block to
the pool over virtio-blk. ~270us for a single 8-128k sync write over virtio-blk (cache=none aio=native) on an
NVMe that does ~110us flushes is ~2x high - candidate causes:
  (a) the SYNC_WRITE zio taskq / completion path adds queue+dispatch latency to each lwb write;
  (b) the virtio-blk WRITE round-trip (not flush) is slow (single submit queue for writes? interrupt
      coalescing? the write completion also funnels - MQ_COMPLETE helped flush completion, does it cover the
      write completion equally?);
  (c) zio_rewrite pipeline stages (checksum/dva/etc.) add fixed per-write cost on OSv.

## NEXT: split the ~270us write latency: submit->device-complete (virtio-blk) vs zio-pipeline overhead. If the
## device write round-trip is ~110us (like the flush) but the zio pipeline adds ~160us, the fix is the zio
## write path; if the virtio-blk WRITE itself is ~270us, the fix is the write submission/completion (transport).

## CONFIRMED SHIPPABLE FIX so far: OSV_BLK_MQ_COMPLETE=1 default-on (+2.1x t32, 0.34x->0.71x Linux). The
## commit-window knob is NOT worth shipping (hurts). The write-latency fix is the remaining lever, pending the
## write-latency split.
