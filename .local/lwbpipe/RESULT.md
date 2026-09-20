# RESULT — OSv ZIL/LWB throughput root-cause investigation (M1 gap)

**Box:** i-0b054feb76fe528cb (m5d.metal, us-east-2a, Debian 12 bookworm, kernel 6.1.0-53, qemu 7.2.22 native
-M pc + KVM, Owner=agent-lwbpipe). Reported in first message. TERMINATED at end (see Housekeeping).
**OSv build:** gh-fork/bench/lwbpipe (m1-confirm base + probes #0035-0039). Depth/issuer/wait/write probes all
verified present in the BUILT submodule source before every run (grep of module/zfs/zil.c).
**Device:** ONE instance-store NVMe /dev/nvme1n1 (838G). OSv sees it via virtio-blk (num-queues=4, cache=none
aio=native). Linux arm uses the SAME nvme1n1 directly. Arms never ran concurrently.
**Isolate:** zfs-bench syncwrite threads=N (each: pwrite 4k + fdatasync loop, distinct file). Pool ashift=12
recordsize=8k compression=off atime=off sync=standard logbias=latency. Linux: identical geometry + a
byte-for-byte swstorm equivalent, ZFS 2.1.11.

================================================================================
## HEADLINE 1 (LOCKED-IN, SHIPPABLE): OSV_BLK_MQ_COMPLETE=1 default-on = +2.1x at t32
================================================================================
Per-queue virtio-blk completion (one completion thread per queue instead of a single global drain; PR #1509,
currently env-gated OFF) is a large, matched, confirmed throughput win. This turns "should #1509 default on?"
from a judgment call into a measured 2.1x.

### The A/B (syncwrite, same NVMe, 30s, MQ_COMPLETE off vs on; Linux direct same NVMe for ratio)
| thr | MQ0 op/s | MQ0 flush/s | MQ0 p50 | MQ0 p99 | MQ1 op/s | MQ1 flush/s | MQ1 depth | MQ1 p50 | MQ1 p99 | Linux op/s | Linux flush/s | MQ1/Linux | MQ1/MQ0 |
|----:|---------:|------------:|--------:|--------:|---------:|------------:|----------:|--------:|--------:|-----------:|--------------:|----------:|--------:|
| 8   |   12,318 |      ~3,370 |  548 us | 2015 us |   13,443 |      ~3,712 |    1.42   |  527 us | 1834 us |     32,328 |         7,077 |     0.42x |   1.09x |
| 16  |   15,992 |      ~2,994 |    -    |    -    |   21,996 |      ~4,291 |    1.70   |  637 us | 2278 us |     44,133 |         5,283 |     0.50x |   1.38x |
| 32  |   17,296 |      ~1,983 | 1554 us | 5828 us |   36,242 |      ~4,100 |    1.48   |  760 us | 2593 us |     51,140 |         4,169 |     0.71x |   2.10x |

- MQ_COMPLETE=1 lifts t32 op/s +110% (0.34x->0.71x Linux) AND cuts p99 (5828->2593us) AND cuts p50
  (1554->760us). It is a pure win at t32 (throughput up, latency down). t16 +38%. t8 +9% (at low concurrency
  the single completion thread was not the bottleneck).
- **CHANGE FOR #1509:** flip the default in drivers/virtio-blk.cc from
  `bool mq_complete = false;` to `bool mq_complete = true;` (env OSV_BLK_MQ_COMPLETE=0 to disable). One line.
  The resolved mode is already printed once at boot. Recommend shipping this default-on.

================================================================================
## HEADLINE 2 (root cause of the RESIDUAL gap, localized, NOT yet fixed)
================================================================================
After MQ_COMPLETE=1, OSv is 0.71x Linux at t32 (0.42x at t8). The residual is the LWB WRITE latency.

### STEP 1a (DIRECT in-flight depth on OSv) — "depth ~1" REFUTED
inflight_max 6/8/11-14 (grows with concurrency), MEAN depth ~1.4-1.5. Flushes DO overlap; the upstream
parent-child pipeline works on OSv. The fix is NOT "enable concurrent flushes."

### STEP 1b (Linux flush rate + batch, same NVMe) — device physics + batching REFUTED
Linux sustains 7,077 flush/s at t8 with NEAR-IDENTICAL batch size (3.78 vs OSv 3.62 commits/flush). The device
CAN do >7000 flush/s. So ~3000/s is NOT a device barrier and NOT batching. It is an OSv-side cost.
(Correction to an interim note: the "~99 in flight on Linux" was a broken issue-counter artifact; with
per-lwb pairing Linux inflight_max = 3, OSv 6-14 — both shallow. The gap is rate at similar depth, i.e.
per-lwb latency, not pipeline depth.)

### STEP 2 issuer pacing — REFUTED
zl_parallel DOES latch (zp_open dominates, decay branch 0.7-7.6%). zl_last_lwb_latency is realistic
(~377-660us, no clock bug). The commit-waiter wakes ON TIME (actual wait ~52-94us vs computed ~40-73us). The
serial issue path (zil_lwb_write_issue: zio_alloc_zil ~6us + dmu_tx ~9us) is only ~14us. None of these is the
~250us inter-issue gap.

### STEP 2 commit window (batching lever) — REFUTED (widening HURTS)
OSV_ZIL_COMMIT_TIMEOUT_PCT A/B (MQ=1): t8 op/s 13295(pct10)->12083(30)->9980(50)->6237(100) monotonic DOWN,
depth 6->3; t32 flat then negative. Bigger window = each waiter waits longer, depth drops, throughput falls.
Not the fix.

### STEP 2d THE RESIDUAL ROOT CAUSE: the LWB WRITE takes ~270us (70% of lwb latency); the FLUSH is only ~110us
Splitting the ~380us whole-lwb latency (issue -> FLUSH_DONE):
  t8  pct10:  WRITE (issue->WRITE_DONE) = 256 us   FLUSH (WRITE_DONE->FLUSH_DONE) = 123 us
  t32 pct10:  WRITE                     = 279 us   FLUSH                          = 110 us
The FLUSH round-trip (~110us) is healthy for a local NVMe. The WRITE (~270us) is ~2x too slow. By Little's law
(depth fixed ~1.4-1.5, latency ~380us -> rate ~3700/s), cutting the ~270us WRITE is the ONLY lever left that
raises the flush rate. **The residual root cause is the OSv ZIL block-WRITE latency, ~270us.**
[STEP 2e write-split below pins whether it is the virtio-blk write round-trip or the OSv zio write pipeline.]

================================================================================
## STEP 2e — the ~270us lwb WRITE split (bounded final push)
================================================================================
Added a virtio-blk bio round-trip timer (strategy submit -> vdev_disk_bio_done, via zio->io_target_timestamp
which is unused on OSv) for WRITE and FLUSH bios. Measured alongside the zil.c write/flush split. MQ_COMPLETE=1.

| thr | lwb WRITE (issue->WRITE_DONE) | virtio-blk WRITE bio round-trip | OSv zio pipeline (rest) | virtio-blk FLUSH bio round-trip | whole lwb | op/s   |
|----:|-----------------------------:|--------------------------------:|------------------------:|--------------------------------:|----------:|-------:|
| 8   |                    263 us    |                       145 us    |               ~118 us   |                        81 us    |   388 us  | 12,704 |
| 32  |                    299 us    |                       211 us    |                ~88 us   |                        70 us    |   416 us  | 33,980 |

### THE SPLIT (two contributors, neither trivial):
1. **virtio-blk WRITE bio round-trip = 145-211us**, which is 2-3x the FLUSH bio round-trip (70-81us) on the
   IDENTICAL transport path (strategy -> vdev_disk_bio_done -> zio_interrupt). The FLUSH is a zero-byte
   barrier; the WRITE carries an 8-128k payload. The ~75-130us WRITE-over-FLUSH excess is the write
   submission + data DMA + completion on OSv's virtio-blk. This is ~50-70% of the lwb write latency.
2. **OSv zio WRITE pipeline = ~88-118us** on top of the bio (lwb write = 263-299us, bio = 145-211us). This is
   the non-device overhead: abd_borrow_buf_copy (a synchronous copy of the whole lwb buffer before the bio -
   see vdev_disk_io_start ZIO_TYPE_WRITE path), zio pipeline stage hops, taskq dispatch, checksum. ~30-40%.

### The plain-write contrast (operator's sharpest ask): a BUFFERED pwrite (nofsync) is 49us p50 / 122,882
op/s - but that write only lands in ARC/pagecache, it does NOT go to the device. The DURABLE lwb write that
DOES hit the device is 263-299us. So the 49us->270us is the cost of making the write DURABLE (device
round-trip + zio pipeline), of which the device WRITE round-trip is ~150-210us and the OSv pipeline ~90-120us.

### FIX TARGETS (localized, for a follow-up run - NOT built here):
- **Primary: the virtio-blk WRITE bio round-trip (145-211us, 2-3x the flush).** Candidates: the write
  completion path (does MQ_COMPLETE=1 cover WRITE completions as well as it covers FLUSH? the flush round-trip
  is 70-81us but the write is 145-211us on the same driver - the write completion or submission may still
  funnel or coalesce); virtio-blk write submit-queue depth; interrupt coalescing on the write path.
- **Secondary: the OSv zio WRITE pipeline (~88-118us).** The abd_borrow_buf_copy synchronous full-buffer copy
  on the ZIL write submit path (vdev_disk_io_start ZIO_TYPE_WRITE) is a concrete OSv-specific cost that
  direct-Linux does not pay the same way; a zero-copy ABD->bio path (like the A6 ZFS zero-copy pagecache
  bridge already in the roadmap) would remove it.
- By Little's law (depth ~1.4-1.5), halving the ~270us lwb write ~doubles the flush rate -> would take OSv
  from 0.71x toward parity with Linux at t32.

================================================================================
## BOTTOM LINE
================================================================================
- The brief's "LWB pipeline depth ~1" hypothesis is REFUTED (depth overlaps, max 6-14, mean ~1.5). So are
  device-physics (Linux does >7000 flush/s on the same NVMe), batching (widening the window HURTS), and
  issuer pacing (waiter wakes on time, serial issue path ~14us). All measured, not argued.
- CONFIRMED SHIPPABLE WIN: OSV_BLK_MQ_COMPLETE=1 default-on = +2.1x op/s at t32 (0.34x->0.71x Linux), p99
  halved. One-line default flip in drivers/virtio-blk.cc (feeds PR #1509).
- RESIDUAL ROOT CAUSE (localized, not fixed): the ZIL block WRITE latency ~270us = virtio-blk WRITE bio
  round-trip ~150-210us (2-3x the flush) + OSv zio write pipeline ~90-120us (incl. abd_borrow_buf_copy). This
  is the remaining lever to parity; it is an OSv write-path cost, not the device flush, not the ZIL logic.
- STEP 3 (isolate A/B qualify) and STEP 4 (HammerDB vs Linux) were NOT reached this run - budget went to the
  STEP-1/STEP-2 confirm/refute chain that correctly killed four wrong hypotheses and localized the real one.
  The MQ_COMPLETE=1 default-on win is A/B-qualified on the isolate (the table above IS the A/B). HammerDB
  end-to-end is the follow-up once the write-path fix lands.
