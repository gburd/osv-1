# Local working-tree state after this run (READ BEFORE COMMITTING)

Three files are modified in the local tree with VALIDATION INSTRUMENTATION,
NOT the clean production fix:

  core/pagecache.cc                       -- the write_cache.empty() guard PLUS
                                             bench-only atomic counters
                                             (osv_wb_calls/skipped/pages_scanned/
                                             pages_flushed) + osv_wb_stats() /
                                             osv_wb_skipped_count() C readers.
  scripts/bench/zfs-bench.c               -- added syncmode=, capmb=, mmapfsync
                                             workload, wb_stats printing.
  exported_symbols/osv_module_api.symbols -- exported osv_wb_stats,
                                             osv_wb_skipped_count for the .so.

The PRODUCTION FIX is the parent's commit 05d5d7944 -- just the two-line guard
in writeback_inode:
    if (write_cache.empty())
        return 0;

For the real change: use 05d5d7944 (clean). The bench harness additions
(syncmode/capmb/mmapfsync) are useful to keep for future ZFS microbench work
but are separate from the fix. The counters in pagecache.cc were only to PROVE
the guard fires (skipped==calls) and finds nothing (pages_flushed=0) during
validation; they should NOT ship -- drop them, keep only the guard.

Recommendation: `git checkout core/pagecache.cc exported_symbols/osv_module_api.symbols`
to discard the instrumented versions, then rely on 05d5d7944 for the fix.
Optionally keep the zfs-bench.c harness additions (syncmode/capmb/mmapfsync) as
a separate commit -- they are reusable instruments, not debt.
