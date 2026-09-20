# The fix is written and applies to master. It is NOT filed - it must be validated first.

## Root cause CONFIRMED (agent f1c38a4d, file-size-scaling test)
    file cap    fdatasync p50 (sync=disabled, ZIL bypassed)
      8 MiB       11.3us
     64 MiB       73.7us
    256 MiB      283.3us
    512 MiB      489.9us
Dead linear at ~1.1us/MiB (~4.5ns/page x2 phases). At 512 MiB it EXCEEDS the prior full-ZIL+flush 448us
with the ZIL DISABLED. writeback_inode's whole-file O(filesize) scan is confirmed as the dominant tax.
This is the FOURTH hypothesis; the first three (inline interrupt stage, honoured batch window, device
flush) were each refuted by a cheap measurement. This one is measured, not reasoned.

## The fix (committed 05d5d7944 on the proven base; cherry-picks CLEAN to master)
core/pagecache.cc writeback_inode(): return early when write_cache.empty(). The write cache holds only
writable-MAP_SHARED faulted pages (single insert() call site, mmap-fault-only - verified on BOTH the
proven base and master). A write()/pwrite() workload (PostgreSQL) has zero pages there, so an empty
cache cannot hold a dirty page for any inode: nothing to flush, skip the scan. Correctness verified:
  - insert() is mmap-write-fault-only on master (call site 833) -> premise holds upstream.
  - the only callers are sys_fsync and the osv_pagecache_writeback_inode C wrapper -> guard safe for all.
  - leaves mmap-writeback behaviour unchanged whenever there ARE cached write pages.
  - PAGECACHE_KH/to_flush: early return happens before any allocation, so no coherence concern.

ponytail note in-code: whole-cache empty() guard removes the tax for the write() case; a large file
with a few dirty mmap pages elsewhere still scans its range - add a per-inode dirty-offset index only if
a mixed mmap+write workload ever needs it. YAGNI: PG never mmaps data files writable.

## WHY IT IS NOT FILED YET (the campaign rule, and three refuted hypotheses earned it)
A fix is a hypothesis until measured. Before any PR:
1. Re-run the syncwrite isolate WITH the fix on ZFS-on-NVMe. PREDICTION: fdatasync p50 drops from
   ~448us toward ~185us (Linux), and the file-size slope goes FLAT (no more O(filesize) scan).
   Also verify the isolate still passes with mmap writes + msync (the path the guard must NOT break).
2. Only if the isolate confirms: re-run HammerDB VU8/32/64 on a base with this fix, matched one-variable
   A/B (fix on/off, same image). PREDICTION: NOPM lifts, and the declining SHAPE flattens, because the
   per-fsync tax that grew with DB size is gone.
3. File the PR with BOTH the isolate delta and the HammerDB delta pasted. Master-facing, no fork deps.

## What could still refute it (stay honest)
- If the isolate does NOT drop with the fix, the guard is not being hit (write_cache non-empty for some
  other reason) - investigate before filing.
- The HammerDB gap has TWO components (level + shape). This fix targets the per-fsync tax = plausibly
  the shape (grows with size) AND part of the level. It will NOT necessarily reach full Linux parity;
  claim only what the numbers show.

## Correctness regression to test explicitly
The guard must not break mmap durability: a process that mmaps a file writable, dirties a page, and
fsyncs MUST still flush. With the fix, write_cache is non-empty in that case, so the scan runs as before.
The isolate should include an mmap+msync/fsync case to prove the guard preserves that path.

## ISOLATE VALIDATION: DONE, PASSED (agent f1c38a4d, 2026-09-12)
Applied the guard on the box, rebuilt, re-ran the isolate:
    file      pre-fix p50   post-fix p50 (sync=standard)
    8 MiB       11us          98.7us
    64 MiB      74us         106.4us
    256 MiB    283us         111.8us
    512 MiB    490us         104.5us
POST-FIX IS FLAT (~104us) across a 64x file-size range; the linear climb is GONE. Guard counters:
skipped==calls (100%), pages_scanned=0 on every syncwrite fsync. Apples-to-apples same sync=standard:
pre-fix 363-449us -> post-fix 104.5us = 3.5-4.3x lower, and BELOW Linux 185us.

MMAP DURABILITY REGRESSION: PASS. A new mmapfsync workload (mmap RW, write pattern, msync+fsync, reopen
fresh, read-verify) passed; counters show pages_scanned=192 (the scan STILL runs when write_cache is
non-empty), so the guard only short-circuits when there is genuinely nothing to flush. Data reached disk.

Box terminated, 0 orphans. Isolate half of qualification COMPLETE.

## REMAINING before filing: the HammerDB half (end-to-end A/B on a fixed base)
Same-binary A/B, one variable (the guard on/off), 200wh/19GB, VU8/32/64, quiesced. PREDICTION:
  - NOPM lifts (the per-fsync tax that scaled with file size is gone).
  - The declining SHAPE flattens or reverses (the tax grew with DB size; removing it should let OSv
    hold or scale instead of decline).
  - This may finally EXPLAIN the two null A/Bs: with the dominant per-fsync cost removed, ZIL/dentry
    effects that were masked by it may become visible - or the gap may close outright.
File the PR (master-facing, no fork deps) with BOTH the isolate table AND the HammerDB delta pasted.
Claim only what the numbers show; the gap has a level and a shape component and this fix targets the
per-fsync tax that plausibly drives both.
