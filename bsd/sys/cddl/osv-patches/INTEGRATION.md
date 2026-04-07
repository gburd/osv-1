# ZFS-OSv Integration Architecture

This document describes how ZFS is integrated into the OSv unikernel,
covering initialization, callback registration, VFS integration, and
memory management hooks.

## Overview

OSv uses a modified version of the illumos ZFS codebase as ported to
FreeBSD (~2013, pre-OpenZFS unification). The ZFS code lives in
`bsd/sys/cddl/contrib/opensolaris/` and is compiled into `libsolaris.so`.
OSv-specific modifications are guarded by `#ifdef __OSV__` /
`#ifndef __OSV__` preprocessor conditionals.

The integration follows a callback-based architecture: `libsolaris.so`
registers function pointers into the OSv kernel at load time, avoiding
hard compile-time dependencies between the kernel and ZFS.

## Initialization: Constructor Pattern

**File:** `fs/zfs/zfs_initialize.c:60`

ZFS initialization is triggered by `libsolaris.so` being loaded via the
`__attribute__((constructor))` mechanism:

```c
void __attribute__((constructor)) zfs_initialize(void) {
    // Guard against double-init
    if (zfs_driver_initialized) return;

    // 1. Initialize thread pools and resources
    opensolaris_load(NULL);
    callb_init(NULL);
    system_taskq_init(NULL);

    // 2. Register callbacks
    register_osv_zfs_ioctl(&osv_zfs_ioctl);
    register_shrinker_arc_funs(&arc_lowmem, &arc_sized_adjust);
    register_pagecache_arc_funs(
        &arc_unshare_buf, &arc_share_buf,
        &arc_buf_accessed, &arc_buf_get_hashkey);

    // 3. Register VFS operations
    zfs_update_vfsops(&zfs_vfsops);

    // 4. Start pagecache access scanner
    start_pagecache_access_scanner();

    // 5. Initialize ZFS subsystem
    zfs_init();

    zfs_driver_initialized = true;
}
```

## Callback Registrations

### 1. ioctl dispatch (`register_osv_zfs_ioctl`)

- **Kernel side:** `drivers/zfs.cc`
- **ZFS side:** `osv_zfs_ioctl()` in zfs_ioctl.c
- **Purpose:** Routes ZFS ioctl commands from the OSv device layer to
  the ZFS ioctl handler, bypassing FreeBSD's cdevsw mechanism.

### 2. ARC shrinker (`register_shrinker_arc_funs`)

- **Kernel side:** `bsd/porting/shrinker.cc`
- **ZFS side:** `arc_lowmem()` and `arc_sized_adjust()` in arc.c
- **Purpose:** Allows the OSv memory manager to reclaim ARC cache memory
  under memory pressure. `arc_lowmem()` is called on low-memory events;
  `arc_sized_adjust()` requests a specific amount of memory reclamation.

### 3. Pagecache-ARC bridge (`register_pagecache_arc_funs`)

- **Kernel side:** `core/pagecache.cc`
- **ZFS side:** `arc_unshare_buf()`, `arc_share_buf()`,
  `arc_buf_accessed()`, `arc_buf_get_hashkey()` in arc.c
- **Purpose:** Integrates ARC buffers with the OSv pagecache. Enables
  sharing of buffer data between ARC and pagecache to avoid double
  caching. The hashkey functions allow the pagecache to track ARC
  buffer identity.

### 4. VFS operations (`zfs_update_vfsops`)

- **Kernel side:** VFS layer (vfssw configuration)
- **ZFS side:** `zfs_vfsops` struct in zfs_vfsops.c
- **Purpose:** Registers ZFS mount/unmount/sync operations with the OSv
  VFS layer at runtime, replacing a dummy entry.

## Memory Locking Annotation

**File:** `fs/zfs/zfs_initialize.c:103`

```c
asm(".pushsection .note.osv-mlock, \"a\"; .long 0, 0, 0; .popsection");
```

This ELF note section tells the OSv dynamic linker to pre-fault (MAP_POPULATE)
all segments of `libsolaris.so` when it is loaded. This prevents page faults
during ZFS operations that handle mmap/munmap on ZFS files, avoiding deadlocks
where a page fault handler would need to call back into ZFS.

## Key Modification Categories

### Category 1: Complete Rewrites

- **vdev_disk.c** - Entirely rewritten to use OSv's bio/device layer
  instead of FreeBSD GEOM. Uses `alloc_bio()`, `destroy_bio()`,
  `bio_wait()`, and `device_open()`/`device_close()` APIs. Async I/O
  completion via `bio->bio_done` callback that calls `zio_interrupt()`.

### Category 2: VFS/Vnode Adaptations

- **zfs_vnops.c** - Removes mandatory locks, mapped reads, xvattr, vrecycle
- **zfs_vfsops.c** - Removes security policy checks, uses `release_mp_dentries()`
  instead of `vflush()`, syncs all pools on last dataset unmount
- **zfs_znode.c/h** - Adds manual `z_ref_cnt` reference counting
- **zfs_dir.c** - Removes DNLC (Directory Name Lookup Cache) and vnode
  mount point locking

### Category 3: Memory/Resource Management

- **arc.c** - Disables DNLC purge, FreeBSD memory throttle, prefetch
  tuning; adds `vm_throttling_needed()` check
- **zio.c** - Forces PAGESIZE alignment for data buffer caches

### Category 4: Stubbed-out Features

- **zfs_ioctl.c** - Stubs: destroy, rollback, recv, send, diff,
  userspace_one/many, jail/unjail
- **zfs_replay.c** - Stubs: TX_CREATE_ACL, TX_LINK, TX_SETATTR,
  TX_ACL_V0, TX_ACL
- **zvol.c** - Stubs: all GEOM-based zvol operations
- **dsl_dataset.c** - Stubs: snapshot unmount, onexit cleanup
- **dmu_objset.c** - Stubs: snapshot security policy, temporary snapshots

### Category 5: Removed FreeBSD/Solaris-specific Code

- **spa_history.c** - Removes jail-based zone hostname lookup
- **dsl_dir.c** - Removes zvol_rename_minors/zfsvfs_update_fromname
- **dmu.c** - Removes ru_oublock accounting
- **arc.c** - Removes ru_inblock accounting

### Category 6: Kernel/Userspace Boundary Changes

- **zfs_prop.c, zpool_prop.c, zprop_common.c** - Makes property
  description functions available in kernel mode (normally userspace-only)

## Root Pool Discovery

**File:** `spa.c:4018-4044` (OSv-specific `zpool_get_config`)

OSv provides its own root pool discovery mechanism via
`vdev_disk_read_rootlabel()` (defined in `vdev_disk.c:251`). This replaces
FreeBSD's GEOM-based label reading. The function reads vdev labels directly
from the block device using synchronous bio I/O, with page-aligned buffer
allocation via `posix_memalign()`.

## Porting Notes for OpenZFS Update

When porting these modifications to a newer OpenZFS codebase:

1. **vdev_disk.c** must be completely rewritten again for the new vdev_disk
   interface in OpenZFS 2.x (which uses ABD - Abstract Buffer Data).
2. **ARC changes** in OpenZFS 2.x are substantial (scattered ABD integration,
   new eviction policies). The OSv hooks (shrinker, pagecache bridge) need
   to be re-evaluated against the new ARC architecture.
3. **Stubbed functions** should be reviewed: OpenZFS may have reorganized or
   removed some of the features that were stubbed out.
4. **znode reference counting** may need rework if OpenZFS changed the
   znode lifecycle model.
5. **Property visibility** changes may not be needed if OpenZFS restructured
   the kernel/userspace split.
