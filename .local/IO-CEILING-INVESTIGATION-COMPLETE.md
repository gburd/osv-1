# The I/O completion ceiling: root-caused, fixed, isolate-validated. HammerDB confirmation running.

## The question (operator directive)
Investigate and improve OSv's I/O layer that completes and wakes on blocked I/O; when the ceiling is
removed, qualify and publish a PR.

## The path (four hypotheses, three refuted by measurement, one confirmed)
1. "Inline the zio interrupt-taskq stage" - REFUTED: nofsync (plain write completion) OSv 6.1us =
   Linux 6.5us. The interrupt hop carries no single-thread tax.
2. "The honoured ZIL batch window is the cost" - REFUTED: the base already has the correct hires fix;
   the 448us was measured WITH it, and the old broken version was accidentally faster single-threaded.
3. "The device FLUSH round-trip" - REFUTED: host cache A/B sized phase B at only ~32us.
4. "The fsync-entry whole-file pagecache scan" - CONFIRMED by file-size scaling: fdatasync p50 dead
   linear at ~1.1us/MiB (11/74/283/490us at 8/64/256/512 MiB), sync=disabled, ZIL bypassed. At 256 MiB
   the counters showed pages_scanned=3.08 BILLION, pages_flushed=0.

## Root cause
core/pagecache.cc writeback_inode(): sys_fsync calls it over the WHOLE file (0..st_size) before
VOP_FSYNC, scanning every page TWICE under the global write_lock. The write_cache only holds
mmap-faulted pages (single insert site), so a write()/pwrite() workload (PostgreSQL) flushes zero pages
while paying an O(filesize) scan on every fsync - growing with DB size, which is the declining-throughput
shape.

## The fix (2 lines, master-facing, no fork deps)
    if (write_cache.empty())
        return 0;
Committed 05d5d7944; pushed CLEAN to gh-fork/pr/fsync-writeback-guard (9fb78af4b). A/B bench branch
gh-fork/bench/fsync-writeback-ab adds OSV_PAGECACHE_FSYNC_SCAN to force the old scan for a same-binary A/B.

## Isolate validation (DONE, PASSED)
- syncwrite sync=standard post-fix: FLAT ~104us across 8-512 MiB (was 11-490 linear); skipped==calls
  100%, pages_scanned=0. 3.5-4.3x lower than pre-fix, BELOW Linux 185us.
- mmap durability regression PASS: scan still runs when write_cache non-empty (pages_scanned=192),
  data verified on fresh read. Guard only short-circuits when truly nothing to flush.

## HammerDB validation (RUNNING, agent 384675c3, boxes i-0ae60ac03c7f72bbc + i-05d7034dfaaae8350)
Same-binary A/B, OSV_PAGECACHE_FSYNC_SCAN on/off, VU8/32/64, 200wh/19GB, wait histogram. Answers: does
the per-fsync win lift NOPM and flatten the declining shape? Prediction: delta GROWS with VU (bigger
working set -> bigger files -> more scan). Honest null accepted if it does not translate.

## Filing gate
PR pr/fsync-writeback-guard lands only when BOTH the isolate table (done) AND the HammerDB delta are
pasted in the PR. Master-facing, generic (every fsync-heavy OSv workload benefits), PG as forcing
function. If HammerDB is a null, file on isolate+correctness merits and claim no NOPM win.

## Local hygiene done
Discarded the agent's validation instrumentation from the main tree (core/pagecache.cc,
exported_symbols/osv_module_api.symbols, scripts/bench/zfs-bench.c) via targeted checkout - the clean
fix is safe at 9fb78af4b. The committed syncwrite isolate f45dac0db remains. Reusable bench harness
additions (syncmode/capmb/mmapfsync) NOT kept in main tree - can be re-added as a separate commit if
wanted for future ZFS microbench work.

## Session PR tally
Filed: #1505 (ZIL hires timeout), #1506 (OSV_ZFS_ARC_MAX). Ready-but-gated: pr/fsync-writeback-guard
(awaiting HammerDB). Bench branches: zil-hires-ab-v2, dentry-perchain-ab, fsync-writeback-ab.
Isolate tool: zfs-bench syncwrite (f45dac0db).
