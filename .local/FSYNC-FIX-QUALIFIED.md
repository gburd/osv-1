# fsync writeback-scan fix: QUALIFIED. Isolate + correctness + checkpoint + tail latency. No NOPM win.

## The full evidence chain (all measured, one variable per experiment)
### Isolate (single-thread syncwrite, OSv vs Linux, then guard on/off)
- OSv fdatasync tax was an O(filesize) whole-file pagecache scan: p50 linear 11/74/283/490us at
  8/64/256/512 MiB; at 256 MiB pages_scanned=3.08 BILLION, pages_flushed=0.
- WITH fix: FLAT ~104us across 64x file-size range, 3.5-4.3x lower, BELOW Linux's 185us.
- mmap durability regression: PASS (scan still runs when write_cache non-empty).

### HammerDB A/B (same-binary, OSV_PAGECACHE_FSYNC_SCAN on/off, 200wh/19GB, valid A/B - two different
    PGCFLAG console lines on one image)
- NOPM: VU8 47188 vs 48745 (-3.3%), VU32 33420 vs 32192 (+3.8%) = NULL, within spread. NO throughput win.
- Checkpoint duration: OLD 168->249->438s (grows with DB/WAL size, VU32 616s) vs FIXED flat ~50-86s.
  3-8x (VU8) to 7x (VU32) reduction. THIS is the size-growing scan translated to an operational metric.
- Tail latency VU32: FIXED NEWORD p99 58.6ms vs OLD 70.5ms = -16.9%.
- Wait shift (VU8 arm medians, per the histogram-median rigor the agent insisted on): OLD WALWrite 40.1%
  vs FIXED 24.2%, OLD NULL 44.7% vs FIXED 62.6% = the predicted direction, fix eases WAL-fsync serialization.

## Why no NOPM win (understood, not hand-waved)
At VU32 an ARM-INDEPENDENT OSv idle-stall dominates: ~85-90% NULL wait, driver 98% idle, NVMe 15% util,
qemu CPU->0 mid-window. Same ceiling the dentry run found. It is NOT the fsync scan - it gates NOPM at
VU32 regardless of the fix, masking the fsync win. So the fsync fix is real and removes a real
size-growing tax; a DIFFERENT (scheduler/wakeup) ceiling caps peak NOPM. Two separate problems.
VU64 not run: guest wedges (FIXED) / OOMs at 37.6/64GB (OLD) at VU32 full-length - a substrate ceiling.

## Filing decision
FILE pr/fsync-writeback-guard, master-facing, honest scope:
  - HEADLINE: eliminates an O(filesize) per-fsync scan that flushes nothing for write()-based I/O.
  - CLAIM: isolate 3.5-4.3x lower fdatasync p50 (flat with file size); checkpoint duration 3-7x lower
    and no longer growing with DB size; tail latency -16.9%; WAL-fsync wait eased.
  - EXPLICITLY DO NOT CLAIM: a peak-NOPM throughput win (measured null; a separate OSv idle-stall caps
    NOPM at these VUs).
  - Correctness: mmap-write durability preserved (regression tested).

## The next ceiling (named, for a future investigation)
The arm-independent VU32 idle-stall (~85-90% NULL, driver+device+CPU all idle, qemu CPU->0 mid-window)
is the SAME OSv-side wakeup/scheduling ceiling the dentry run localised. It is now the top throughput
target, and it is NOT in the IO completion path (isolate proved plain writes match Linux) - it is in how
OSv schedules/wakes many threads. That is the next generic (G2) investigation.

## FILED: PR #1507
gburd:pr/fsync-writeback-guard -> cloudius-systems/osv:master, OPEN, merge-tree CLEAN, G-signed 9fb78af4b.
Body carries the full evidence: isolate table (flat p50, 3.5-4.3x, 3.08B scans/0 flushes), mmap
durability PASS, and the end-to-end wins (checkpoint 3-7x lower and no longer growing with DB size, tail
p99 -16.9%, WAL-wait eased). EXPLICITLY does not claim a NOPM win (measured null). Em-dashes stripped
from body for the no-em-dash rule; commit message clean. 0 EC2 orphans across all six benchmark agents.

## The directive is answered
"Investigate and improve the OSv I/O layer that completes and wakes on blocked I/O; when the ceiling is
removed, qualify and publish a PR."
- Investigated: traced the full virtio-blk -> biodone -> vdev_disk -> zio -> ZIL -> fdatasync path.
- Found: the ceiling was NOT in the completion/wakeup path (plain writes match Linux to 0.4us). It was
  a VFS-layer O(filesize) whole-file scan on every fsync, above the ZIL, flushing nothing for write().
  Four hypotheses, three refuted by measurement, one confirmed by file-size scaling.
- Improved: a 2-line guard removing the scan when nothing is dirty; isolate p50 flat and below Linux.
- Qualified: isolate + correctness + checkpoint 3-7x + tail -16.9%, honest NOPM null.
- Published: PR #1507.

The completion/wakeup path the directive named turned out NOT to be the ceiling - the measurement said
so, and I followed the measurement rather than the framing. The remaining NOPM ceiling is a separate
OSv scheduling/wakeup stall (arm-independent, ~85-90% NULL at VU32), which is the next G2 target.
