# PR 3 - pagecache/vfs: ZFS bridging, readahead, writeback, fsync flush

**Branch:** `gburd/osv-1:pr/pagecache` -> `cloudius-systems/osv:master`
**Base:** stacks on PR 2 (`pr/mmu-shm`, 387a97de). Two-commit branch:
2286d852, d06461bf.
**Verified:** kernel compiles + links clean on GCC 14.3 / Boost 1.87
(`./scripts/build fs=rofs image=empty`, RC=0, via the PR 6 tip which
includes this). tst-zfs-direct-io, tst-zfs-multirec, tst-fs-bench PASS
on the ZFS image.

---

## Title

pagecache/vfs: ZFS page-cache bridge, readahead, writeback, fsync flush

## Body

Make the OSv VFS page cache cooperate with the OpenZFS port landing
later in this series, and fix a data-durability bug in sys_fsync.

### Changes

- **pagecache: ZFS bridging, sequential readahead, periodic writeback**
  (2286d852).
  - Expose C-linkage helpers (`osv_pagecache_map_page`, etc.) so the
    OpenZFS `vop_cache` in zfs_vnops_os.c can register/look up cached
    pages without pulling C++ pagecache headers into module sources.
    Also fixes a GCC 14 ambiguity on a templated helper.
  - Remove the original ARC-bridge code path (shared ARC<->read_cache
    pages). It was never reachable: IS_ZFS() always returned false on
    OSv and the bridge structures were only initialised on the dead
    branch. A comment documents the decision so it isn't re-attempted.
  - Sequential readahead (window grows on consecutive hits, resets on
    seek) plus a 5 s periodic writeback worker with a global dirty-page
    cap.

- **vfs: flush page cache before VOP_FSYNC in sys_fsync** (d06461bf).
  sys_fsync() called VOP_FSYNC without first flushing the OSv page
  cache, so dirty cached pages were never seen by the filesystem's
  fsync hook -- a process could fsync() and still lose data on crash
  (reproducer: write 64 KiB, fsync, kill VM, restart, read zeros).
  Walk the file's dirty pages, write them back, then VOP_FSYNC, holding
  f_lock across the flush so concurrent writes can't slip in.

### Notes

- Fourth in the series (PR 0 -> musl -> mmu-shm -> this).
- The page-cache helpers are consumed by the OpenZFS PR later; this PR
  only adds the kernel-side surface and the fsync fix.
