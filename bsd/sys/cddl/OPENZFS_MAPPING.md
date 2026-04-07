# OpenZFS Path Mapping

Maps OSv's current ZFS files (illumos/FreeBSD ~2013 port) to their
equivalents in OpenZFS 2.3.6 (`external/openzfs/`).

## OpenZFS Source Layout

OpenZFS uses a platform-split architecture:

```
module/zfs/           - Platform-independent ZFS code
module/os/freebsd/zfs/ - FreeBSD OS-specific code
module/os/linux/zfs/   - Linux OS-specific code
module/zcommon/        - Common property/utility code
include/sys/          - Platform-independent headers
include/os/freebsd/zfs/sys/ - FreeBSD-specific headers
```

For an OSv port, we would create `module/os/osv/zfs/` and
`include/os/osv/zfs/sys/` following the existing platform pattern.

## File Mapping

### Critical Rewrites

| OSv Current Path | OpenZFS Path | Notes |
|---|---|---|
| `uts/common/fs/zfs/vdev_disk.c` | `module/os/linux/zfs/vdev_disk.c` (Linux) / `module/os/freebsd/zfs/vdev_geom.c` (FreeBSD) | OSv needs its own `module/os/osv/zfs/vdev_disk.c`. OpenZFS renamed FreeBSD's vdev_disk to vdev_geom. New ABD (Abstract Buffer Data) API replaces raw buffer pointers. |

### Platform-Independent (module/zfs/)

| OSv Current Path | OpenZFS Path | API Changes |
|---|---|---|
| `uts/common/fs/zfs/arc.c` | `module/zfs/arc.c` + `module/os/freebsd/zfs/arc_os.c` | Split into platform-independent and OS-specific parts. New ABD integration, scattered I/O support, new eviction model. OSv hooks need `module/os/osv/zfs/arc_os.c`. |
| `uts/common/fs/zfs/zfs_ioctl.c` | `module/zfs/zfs_ioctl.c` + `module/os/freebsd/zfs/zfs_ioctl_os.c` | Split. OS-specific ioctl dispatch in `zfs_ioctl_os.c`. Many operations refactored (destroy uses `dsl_destroy`). |
| `uts/common/fs/zfs/zfs_replay.c` | `module/zfs/zfs_replay.c` | Significant refactoring. Check if stubbed operations are still needed. |
| `uts/common/fs/zfs/spa.c` | `module/zfs/spa.c` + `module/os/freebsd/zfs/spa_os.c` | Root config discovery moved to OS-specific file. OSv needs `module/os/osv/zfs/spa_os.c`. |
| `uts/common/fs/zfs/spa_history.c` | `module/zfs/spa_history.c` | Minor changes expected. Zone/jail code may be in OS layer now. |
| `uts/common/fs/zfs/zvol.c` | `module/zfs/zvol.c` + `module/os/freebsd/zfs/zvol_os.c` | Split. GEOM code in OS-specific file. OSv can provide empty `zvol_os.c`. |
| `uts/common/fs/zfs/zio.c` | `module/zfs/zio.c` | ABD integration changes buffer allocation. Page alignment may be handled differently. |
| `uts/common/fs/zfs/dsl_dir.c` | `module/zfs/dsl_dir.c` | Rename operations refactored. |
| `uts/common/fs/zfs/dsl_dataset.c` | `module/zfs/dsl_dataset.c` | Hold/release refactored into `dsl_userhold.c`. Onexit code may be in OS layer. |
| `uts/common/fs/zfs/dmu_objset.c` | `module/zfs/dmu_objset.c` | Snapshot operations refactored. |
| `uts/common/fs/zfs/dmu.c` | `module/zfs/dmu.c` + `module/os/freebsd/zfs/dmu_os.c` | Split. Resource accounting in OS-specific file. |

### FreeBSD OS-Specific -> OSv OS-Specific

These files in `module/os/freebsd/zfs/` need OSv equivalents in
`module/os/osv/zfs/`:

| FreeBSD File | Purpose | OSv Strategy |
|---|---|---|
| `arc_os.c` | Memory pressure detection, prefetch tuning | Implement with vm_throttling_needed(), skip prefetch tuning |
| `dmu_os.c` | Resource accounting (ru_oublock) | Empty / no-op |
| `spa_os.c` | Root pool discovery | Implement with vdev_disk_read_rootlabel() |
| `vdev_geom.c` | Block device I/O via GEOM | Rewrite as vdev_disk.c using OSv bio layer |
| `vdev_label_os.c` | Label reading | Implement with OSv device_open/bio APIs |
| `zfs_acl.c` | ACL operations | Port current OSv changes |
| `zfs_dir.c` | Directory operations | Port (no DNLC, no vn_vfswlock) |
| `zfs_ioctl_os.c` | OS-specific ioctl dispatch | Implement with callback registration |
| `zfs_vfsops.c` | VFS mount/unmount/sync | Implement with OSv VFS layer |
| `zfs_vnops_os.c` | Vnode operations | Implement without mapped reads, mandatory locks |
| `zfs_znode_os.c` | Znode lifecycle | Implement with z_ref_cnt manual refcounting |
| `zvol_os.c` | Volume device management | Stub out (no GEOM) |

### Headers

| OSv Current Path | OpenZFS Path | Notes |
|---|---|---|
| `uts/common/fs/zfs/sys/zfs_context.h` | `include/sys/zfs_context.h` + `include/os/freebsd/zfs/sys/zfs_context_os.h` | Split. OS-specific context in separate header. OSv needs `include/os/osv/zfs/sys/zfs_context_os.h`. |
| `uts/common/fs/zfs/sys/zfs_znode.h` | `include/sys/zfs_znode.h` + `include/os/freebsd/zfs/sys/zfs_znode_impl.h` | Split. z_ref_cnt goes in OSv's `zfs_znode_impl.h`. |

### Common Property Code (module/zcommon/)

| OSv Current Path | OpenZFS Path | Notes |
|---|---|---|
| `common/zfs/zfs_prop.c` | `module/zcommon/zfs_prop.c` | Check if kernel visibility guard still needed. |
| `common/zfs/zpool_prop.c` | `module/zcommon/zpool_prop.c` | Check if kernel visibility guard still needed. |
| `common/zfs/zprop_common.c` | `module/zcommon/zprop_common.c` | Check if kernel visibility guard still needed. |

## Major API Changes in OpenZFS 2.x

### ABD (Abstract Buffer Data)
- All I/O uses `abd_t*` instead of raw `void*` buffers
- Supports scattered (page-list) and linear buffers
- `vdev_disk_io_start()` must handle ABD->bio conversion
- Key functions: `abd_alloc()`, `abd_free()`, `abd_borrow_buf()`,
  `abd_return_buf()`, `abd_iterate_func()`

### Platform Abstraction
- OS-specific code cleanly separated into `module/os/<platform>/`
- Headers split similarly: `include/os/<platform>/zfs/sys/`
- Threading, memory, file I/O abstracted through OS layer
- `spl/` (Solaris Porting Layer) integrated into the build

### Taskq
- Task queue API evolved; check for new interfaces
- `system_taskq_init()` may have different signature

### ARC
- New eviction algorithm (ARC has been significantly reworked)
- ABD integration throughout
- Memory management hooks may have different API
- Compressed ARC support

### ZIL/ZIO
- Improved write throttling
- New pipeline stages
- ABD integration in ZIO

## Recommended Porting Approach

1. Create `module/os/osv/` and `include/os/osv/` directory trees
2. Start with SPL (Solaris Porting Layer) adaptations
3. Port vdev_disk (most critical, completely rewritten)
4. Port arc_os.c (memory management hooks)
5. Port zfs_vfsops.c and zfs_vnops_os.c (VFS integration)
6. Port zfs_znode_os.c (reference counting)
7. Port remaining OS-specific files
8. Update build system to include OSv platform
