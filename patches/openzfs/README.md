# OpenZFS Platform Patches for OSv

This directory contains git format-patch files that add the complete OSv platform layer to OpenZFS 2.3.6.

## Overview

**Base**: OpenZFS 2.3.6 (tag `zfs-2.3.6`, commit `c840612ee`)
**Patches**: 2 patches adding ~16,700 lines of OSv-specific code
**Application**: Automatic via `scripts/apply-openzfs-patches.sh`

## Patch Files

### 0001-OSv-Add-complete-platform-layer-with-SPL-for-OpenZFS.patch
- Adds complete OSv platform layer (~15,400 lines)
- Platform headers (include/os/osv/spl/ and include/os/osv/zfs/sys/):
  - arc_os.h - ARC OS-specific definitions
  - zfs_context_os.h - Platform context (TSD, logging, CPU_SEQID)
  - zfs_znode_impl.h - Znode implementation details
  - Complete SPL (Solaris Porting Layer) headers
- Core ZFS implementation (module/os/osv/zfs/):
  - vdev_disk.c - Block device integration
  - vdev_label_os.c - Device label operations
  - arc_os.c - ARC memory management for OSv
  - spa_os.c - Storage pool OS layer
  - dmu_os.c - Data Management Unit OS layer
  - event_os.c - Event handling stubs
  - kmod_core.c - Kernel module initialization
  - sysctl_os.c - Sysctl interface stubs

### 0002-feat-zfs-Add-OSv-OS-layer-implementation-with-auto-u.patch
- Adds OSv-specific ZFS file and directory operations (~1,300 lines)
- File/directory operations:
  - zfs_vnops_os.c - Vnode operations (open, close, read, write, getattr, etc.)
  - zfs_znode_os.c - Znode lifecycle management with manual refcounting
  - zfs_ioctl_os.c - Platform-specific ioctl operations
  - zfs_dir.c - Directory operations
  - zfs_file_os.c - File I/O operations
  - zfs_ctldir.c - Control directory (.zfs) support
  - zfs_acl.c - Access control lists
- Solaris compatibility layer:
  - abd_os.c - Aggregate Buffer Descriptor OS layer
  - spl_uio.c - UIO (User I/O) implementation
- Auto-upgrade feature:
  - zfs_auto_upgrade.c/h - Automatic pool upgrade on import
  - zfs_vfsops.c - VFS operations with auto-upgrade hook
- The auto-upgrade feature automatically upgrades legacy ZFS pools (version < 5000) to the feature flags era (version 5000) on first import

## How Patches Are Applied

### Automatic Application

The patches are applied automatically during the build process:

1. **During setup**: `./scripts/setup.py` calls `apply-openzfs-patches.sh`
2. **Before build**: Build scripts check and apply if needed
3. **Manual**: `./scripts/apply-openzfs-patches.sh`

### What Gets Added

**Platform Headers** (60 files in `include/os/osv/`):
- `include/os/osv/spl/` - Complete Solaris Porting Layer headers
- `include/os/osv/zfs/sys/` - ZFS platform headers including:
  - `arc_os.h` - ARC OS-specific definitions
  - `zfs_context_os.h` - Platform context (TSD, logging, CPU_SEQID)
  - `zfs_znode_impl.h` - Znode implementation details
  - Plus many more ZFS/SPL compatibility headers

**Platform Implementation** (24 files in `module/os/osv/zfs/`):
- Block device layer:
  - `vdev_disk.c` - OSv bio integration
  - `vdev_label_os.c` - Device label operations
- Memory and resource management:
  - `arc_os.c` - ARC (Adaptive Replacement Cache) for OSv
  - `abd_os.c` - Aggregate Buffer Descriptors
- Pool and dataset operations:
  - `spa_os.c` - Storage pool OS layer
  - `dmu_os.c` - Data Management Unit OS layer
- File and directory operations:
  - `zfs_vnops_os.c` - Vnode operations
  - `zfs_znode_os.c` - Znode lifecycle with manual refcounting
  - `zfs_dir.c` - Directory operations
  - `zfs_file_os.c` - File I/O
  - `zfs_ioctl_os.c` - Platform-specific ioctls
  - `zfs_ctldir.c` - Control directory (.zfs)
  - `zfs_acl.c` - Access control lists
- VFS integration:
  - `zfs_vfsops.c` - Mount/unmount operations
  - `zfs_initialize_osv.c` - Module initialization
- Auto-upgrade:
  - `zfs_auto_upgrade.c` - Automatic pool upgrade logic
  - `zfs_auto_upgrade.h` - Auto-upgrade interface
- Compatibility layer:
  - `spl_uio.c` - Solaris UIO implementation
  - `zfs_racct.c` - Resource accounting stubs
- System integration stubs:
  - `event_os.c` - Event handling
  - `kmod_core.c` - Kernel module support
  - `sysctl_os.c` - Sysctl interface
  - `zvol_os.c` - Volume support

**Total**: 84 files, ~16,700 lines

## Regenerating Patches

If you modify the OpenZFS platform layer:

```bash
# 1. Apply existing patches to work on
./scripts/apply-openzfs-patches.sh

# 2. Make your changes
cd external/openzfs
# Edit files in module/os/osv/ or include/os/osv/

# 3. Commit your changes to the appropriate patch
#    - Core platform changes: amend first commit
#    - File/directory operations or auto-upgrade: amend second commit
git add module/os/osv include/os/osv
git commit --amend

# 4. Regenerate patches (overwrites existing)
git format-patch zfs-2.3.6 -o ../../patches/openzfs/

# 5. Reset submodule to clean state (required for main repo)
git checkout zfs-2.3.6

# 6. Test patches apply cleanly
cd ../..
./scripts/apply-openzfs-patches.sh

# 7. Stage the submodule reset in main repo
git add external/openzfs

# 8. Commit your changes to main repo with updated patches
git add patches/openzfs/
git commit -m "OpenZFS: Update platform patches"
```

**IMPORTANT**: Never commit the submodule with applied patches. Always reset to `zfs-2.3.6` tag before committing to the main repository.

## Updating OpenZFS Base Version

To update to a newer OpenZFS version:

1. **Update submodule**:
   ```bash
   cd external/openzfs
   git fetch --tags
   git checkout zfs-2.3.7  # or newer version
   ```

2. **Test patch application**:
   ```bash
   cd ../..
   ./scripts/apply-openzfs-patches.sh
   ```

3. **Fix conflicts** (if any):
   ```bash
   cd external/openzfs
   # Resolve conflicts in each failing patch
   git am --continue  # after fixing each one
   ```

4. **Regenerate patches**:
   ```bash
   git format-patch zfs-2.3.7 -o ../../patches/openzfs/
   ```

5. **Update .gitmodules**:
   ```
   [submodule "external/openzfs"]
       branch = zfs-2.3.7  # update version
   ```

## Architecture

### Platform-Split Model

OpenZFS 2.3.6+ uses a clean platform-split architecture:

```
openzfs/
├── include/
│   └── os/
│       ├── linux/      # Linux platform
│       ├── freebsd/    # FreeBSD platform
│       └── osv/        # OSv platform (our patches)
└── module/
    └── os/
        ├── linux/      # Linux implementation
        ├── freebsd/    # FreeBSD implementation
        └── osv/        # OSv implementation (our patches)
```

**Advantages**:
- No `__OSV__` guards in common code
- Clean separation of concerns
- Easy to update OpenZFS
- Easy to maintain platform code

### Key Adaptations for OSv

**Manual Memory Management**:
- Simple `kmem_alloc()` instead of slab allocators
- No `uma_zone` (FreeBSD) or `kmem_cache` (Linux)

**Manual Reference Counting**:
- `z_ref_cnt` field in znode (OSv lacks vnode refcounting)
- Explicit `zfs_zhold()` / `zfs_zrele()` calls

**ABD Integration**:
- Uses `abd_borrow_buf()` / `abd_return_buf_copy()`
- Matches FreeBSD vdev_geom fallback pattern
- Integrates with OSv bio layer

**Simplified Features**:
- No SMR (Safe Memory Reclamation)
- No extended attributes (xvattr)
- No mandatory file locking
- Simpler vnode model than FreeBSD

## Testing

After applying patches, verify the platform layer:

```bash
# Check files exist
find external/openzfs/module/os/osv -type f
find external/openzfs/include/os/osv -type f

# Count lines
find external/openzfs/module/os/osv -name '*.c' -exec wc -l {} + | tail -1
find external/openzfs/include/os/osv -name '*.h' -exec wc -l {} + | tail -1

# Build OSv with ZFS
./scripts/build arch=aarch64 fs=zfs image=native-example

# Test in QEMU
./scripts/run.py
# Inside OSv:
/# zpool status
/# zfs list
```

## Troubleshooting

### Patches don't apply cleanly

**Cause**: OpenZFS submodule is not at the expected commit

**Solution**:
```bash
cd external/openzfs
git checkout zfs-2.3.6
cd ../..
./scripts/apply-openzfs-patches.sh
```

### "Patches already applied" warning

**Cause**: Platform files already exist in submodule

**Solution**:
- If you want to reapply: Answer 'y' to the prompt
- If patches are already applied: Just continue building

### Build errors after applying patches

**Cause**: Include paths or object definitions may need updating

**Solution**:
1. Check `bsd/sys/cddl/openzfs_sources.mk` for correct include paths
2. Verify `Makefile` includes OpenZFS objects correctly
3. See `BUILD_INSTRUCTIONS.md` for troubleshooting

## References

- **OpenZFS Documentation**: https://openzfs.github.io/openzfs-docs/
- **Platform Integration Guide**: https://github.com/openzfs/zfs/tree/master/module/os
- **FreeBSD ZFS** (closest to OSv): `external/openzfs/module/os/freebsd/`
- **Linux ZFS** (simpler reference): `external/openzfs/module/os/linux/`

## Email Submission

Email-ready patches for upstream submission are in `patches/email-submissions/openzfs/`:
- `0000-cover-letter.patch` - Cover letter explaining the integration
- `0001-OSv-Add-complete-platform-layer-with-SPL-for-OpenZFS.patch` - Platform layer
- `0002-feat-zfs-Add-OSv-OS-layer-implementation-with-auto-u.patch` - File ops and auto-upgrade

See `patches/email-submissions/openzfs/README.md` for submission instructions.

## Maintenance

These patches represent the OSv platform layer for OpenZFS 2.3.6. They should be:

- **Updated** when OpenZFS releases new versions
- **Extended** when new ZFS features are needed
- **Maintained** to stay compatible with OSv core changes

For questions or issues, see:
- `BUILD_INSTRUCTIONS.md` - Build troubleshooting
- `RESUME_ON_LINUX.md` - Complete development guide
- OSv mailing list: osv-dev@googlegroups.com
