Make the OSv VFS page cache cooperate with the OpenZFS port landing later in this series, and fix a data-durability bug in `sys_fsync`.

This branch bases directly on current `master` (3df7df76, the just-merged mmu-shm work). Two commits.

### Changes

- **pagecache: ZFS bridging, sequential readahead, periodic writeback** (54430d8f).
  - Expose C-linkage helpers (`osv_pagecache_map_page`, etc.) so the OpenZFS `vop_cache` in `zfs_vnops_os.c` can register/look up cached pages without pulling C++ pagecache headers into module sources. Also fixes a GCC 14 ambiguity on a templated helper.
  - Remove the original ARC-bridge code path (shared ARC<->read_cache pages). It was never reachable: `IS_ZFS()` always returned false on OSv and the bridge structures were only initialised on the dead branch. A comment documents the decision so it isn't re-attempted.
  - Sequential readahead (window grows on consecutive hits, resets on seek) plus a 5 s periodic writeback worker with a global dirty-page cap.

- **vfs: flush page cache before VOP_FSYNC in sys_fsync** (2ef46420).
  `sys_fsync()` called `VOP_FSYNC` without first flushing the OSv page cache, so dirty cached pages were never seen by the filesystem's fsync hook -- a process could `fsync()` and still lose data on crash (reproducer: write 64 KiB, fsync, kill VM, restart, read zeros). Walk the file's dirty pages, write them back, then `VOP_FSYNC`, holding `f_lock` across the flush so concurrent writes can't slip in.

### Verification

Kernel compiles and links clean on GCC 14.3 / Boost 1.87 (`./scripts/build image=empty`, fresh loader.elf, RC=0). The page-cache helpers are consumed by the later OpenZFS PR; this PR adds only the kernel-side surface and the fsync fix.
