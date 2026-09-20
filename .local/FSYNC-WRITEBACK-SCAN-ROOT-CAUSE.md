# ROOT CAUSE (strong hypothesis, confirmation running): OSv fsync does an O(filesize) pagecache scan

## The decomposition that found it (measured, single-thread, same NVMe)
    OSv syncwrite p50:
      sync=standard   363.0us   (full ZIL log-write + FLUSH)
      sync=DISABLED   297.9us   (fdatasync is a semantic NO-OP: no LWB, no flush)
      nofsync           6.2us   (no fdatasync CALL at all)
    Linux syncwrite p50 (prior run, standard): 185.2us

Three refutations, each by measurement:
  - NOT the flush (B): standard - disabled = only 65us is ZIL-log+FLUSH.
  - NOT the commit-waiter wakeup (C): also inside the ZIL commit, which disabled bypasses.
  - NOT the batch window (D): same.
  - The residual 297.9 - 6.2 = ~292us is the fdatasync SYSCALL ENTRY path, paid even when there is
    nothing to sync.

## The mechanism (traced to source)
- `fdatasync()` calls `fsync()` (fs/vfs/main.cc:614; a TODO admits it does no less than fsync).
- `sys_fsync()` (fs/vfs/vfs_syscalls.cc:380) calls
  `pagecache::writeback_inode(dev, ino, 0, st_size)` on the WHOLE FILE before VOP_FSYNC.
- `writeback_inode()` (core/pagecache.cc:1025) scans `0..st_size` in 4096-byte steps TWICE
  (phase 1 promote-dirty, phase 2 collect), each step a `find_in_cache()` hash lookup, under the
  global `write_lock`. O(filesize) per fsync.
- PostgreSQL (and the syncwrite bench) use write(), not mmap, so the write_cache dirty set is empty and
  to_flush is always empty - the scan finds NOTHING but still traverses every page.

## Arithmetic matches
Bench wraps the file at 1 GiB = 262,144 pages x2 phases = ~524,288 hash lookups/fsync ~ 260us ~ the
measured 292us. And it GROWS with file size - explaining why the end-of-recovery checkpoint (1M buffers)
was ~15 MB/s and why bigger DBs are slower. Linux tracks dirty pages in a radix tree and visits only
dirty ones; it does not re-scan a clean file. That is the OSv-vs-Linux gap.

## The falsifiable prediction under test (agent f1c38a4d, on the existing box)
fdatasync p50 must scale LINEARLY with file size (scan is over 0..st_size). Sweep 16 MiB -> 2 GiB.
  - confirmed: 16 MiB near Linux, 2 GiB well above 448us, roughly linear -> writeback_inode scan is it.
  - refuted: flat across sizes -> the 292us is a fixed per-call cost elsewhere; go find it.

## The fix (generic, G2), IF confirmed
`writeback_inode` (and the fsync path) must not traverse clean ranges:
  1. Skip the scan entirely when the inode has NO cached dirty write pages. A per-inode dirty count or a
     "has any dirty page" flag on the write_cache, checked in O(1), lets an fsync on a file with no
     mmap'd dirty pages return immediately to VOP_FSYNC. PG never mmaps its data files for write, so this
     removes the whole tax for the PG case.
  2. Better: maintain a per-inode list/tree of dirty pages so writeback visits only dirty pages
     (O(dirty), like Linux), instead of scanning 0..st_size. Larger change, helps mmap writers too.
  3. Minimum: fdatasync should not do fsync's full pagecache writeback - but OSv has no separate
     dirty-tracking so (1) is the pragmatic form.
Every fsync-heavy workload on OSv benefits (databases, log writers, anything durable). PG is the forcing
function. This is squarely a platform improvement, not a PG hack.

## Discipline note
This is the FOURTH root-cause hypothesis for this gap. The first three (inline interrupt stage, honoured
batch window, flush) were each plausible and each refuted by a cheap measurement. Do NOT implement until
the file-size-scaling test confirms this one. If it confirms, the fix is small and O(1)-checkable, and
its effect is directly re-measurable with the same syncwrite isolate BEFORE spending on HammerDB.
