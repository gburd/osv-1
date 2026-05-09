# OpenZFS Platform Patches for OSv

This directory contains `git format-patch` files that add the complete OSv
platform layer on top of an OpenZFS release tag.

## Overview

**Base tag**: `zfs-2.4.1`
**Patches**: 3 commits adding the complete OSv platform layer (~16,700 lines)
**Application**: Automatic via `scripts/apply-openzfs-patches.sh`

The patches follow OpenZFS's platform-split architecture.  All OSv-specific
code lives under two directories that do not exist in the upstream source:

```
external/openzfs/
  include/os/osv/        -- platform headers (SPL + ZFS)
  module/os/osv/         -- platform implementation
```

No `#ifdef __OSV__` guards are needed in the common OpenZFS code.

---

## Patch Files

### 0001-OSv-Add-complete-platform-layer-with-SPL-for-OpenZFS.patch

Adds the complete OSv SPL (Solaris Porting Layer) and ZFS platform headers
plus the core implementation files (~15,400 lines).

**Headers added** (`include/os/osv/`):
- `spl/sys/` — 46 headers covering types, memory, synchronization, threads,
  time, I/O, debugging, atomics, byte order, and miscellaneous system types
- `zfs/sys/zfs_context_os.h` — platform context (TSD, logging, CPU_SEQID)
- `zfs/sys/arc_os.h`, `abd_os.h`, `abd_impl_os.h` — ARC/ABD support
- `zfs/sys/zfs_vfsops_os.h` — VFS structures
- `zfs/sys/zfs_znode_impl.h` — znode implementation detail
- `zfs/sys/zfs_vnops_os.h` — vnode operation signatures

**Implementation added** (`module/os/osv/zfs/`):
- `vdev_disk.c` — block device I/O via the OSv bio layer
- `arc_os.c` — ARC memory management for OSv
- `spa_os.c` — storage pool OS layer
- `zfs_vfsops.c` — VFS mount/unmount operations
- `zfs_initialize_osv.c` — module initialisation and `freemem`
- `zfs_debug.c` — debug output support
- `kmod_core.c` — kernel module lifecycle
- Stub files: `zvol_os.c`, `dmu_os.c`, `event_os.c`, `sysctl_os.c`,
  `zfs_ioctl_os.c`, `vdev_label_os.c`

### 0002-feat-zfs-Add-OSv-OS-layer-implementation-with-auto-upgrade.patch

Adds OSv-specific file and directory operations and the auto-upgrade feature
(~1,300 lines).

**File/directory operations**:
- `zfs_vnops_os.c` — vnode operations (open, close, read, write, getattr, …)
- `zfs_znode_os.c` — znode lifecycle with manual `z_ref_cnt` reference counting
- `zfs_ioctl_os.c` — platform ioctl stubs
- `zfs_dir.c` — directory operations
- `zfs_file_os.c` — file I/O operations
- `zfs_ctldir.c` — `.zfs` control directory support
- `zfs_acl.c` — access control list stubs

**Compatibility layer**:
- `abd_os.c` — Aggregate Buffer Descriptor OS layer
- `spl_uio.c` — Solaris UIO implementation

**Auto-upgrade feature**:
- `zfs_auto_upgrade.c` / `zfs_auto_upgrade.h` — automatically upgrades legacy
  ZFS pools (version < 5000) to the feature-flags era on first import

### 0003-OSv-Update-platform-layer-for-OpenZFS-2.4.1-compatibility.patch

Updates the platform layer for API changes introduced between OpenZFS 2.3.6
and 2.4.1, including:
- `zvol_os_remove_minor()` and `zvol_wait_close()` stubs
- `random_get_pseudo_bytes()` definition after `#undef`
- ICP assembly file enablement (`sha256-x86_64.S`, `sha512-x86_64.S`,
  `aes_amd64.S`, `aes_aesni.S`)
- Taskq extensions: `taskq_init_ent`, `taskq_empty_ent`,
  `taskq_dispatch_ent`, and related helpers

---

## Applying the Patches

### Automatic (recommended)

```bash
./scripts/apply-openzfs-patches.sh
```

The script detects the correct base tag from the patches themselves, resets
the submodule if needed, and verifies key files exist after application.

### Check without modifying

```bash
./scripts/apply-openzfs-patches.sh --check-only
```

Exits 0 if all patches would apply cleanly; non-zero otherwise.

---

## Adding a New OSv-Specific Change

1. Apply existing patches so the submodule is in the patched state:
   ```bash
   ./scripts/apply-openzfs-patches.sh
   ```

2. Edit files under `external/openzfs/include/os/osv/` or
   `external/openzfs/module/os/osv/`.

3. Commit your change to the submodule:
   ```bash
   cd external/openzfs
   git add include/os/osv module/os/osv
   git -c commit.gpgsign=false commit -m "OSv: describe your change"
   cd ../..
   ```

4. Regenerate the patch files (overwrites existing ones):
   ```bash
   ./scripts/update-openzfs.sh
   ```
   This saves the new set of commits as patches, resets the submodule to
   the base tag, and re-applies cleanly.

5. Stage both the updated patches and the submodule pointer:
   ```bash
   git add patches/openzfs/ external/openzfs
   git commit -m "zfs: update OSv platform patches"
   ```

**IMPORTANT**: Never commit the submodule while it has the OSv patches applied.
The outer repo must always point the submodule at the base release tag
(`zfs-2.4.1`) so that `git submodule update` gives a clean slate for
`apply-openzfs-patches.sh` to work from.

---

## Updating to a New OpenZFS Version

Use `scripts/update-openzfs.sh`:

```bash
# 1. Fetch new tags into the submodule (only needed if not already local).
git -C external/openzfs fetch --tags

# 2. Update to the new release.
./scripts/update-openzfs.sh zfs-2.5.0
```

The script will:
1. Save the current OSv commits as patches in this directory.
2. Reset `external/openzfs` to `zfs-2.5.0`.
3. Re-apply all patches via `git am`.
4. If a patch fails, print clear instructions to resolve the conflict.
5. Verify that key platform files exist.
6. Update `scripts/apply-openzfs-patches.sh` to reference the new tag.

After a successful run:
```bash
git add external/openzfs patches/openzfs/ scripts/apply-openzfs-patches.sh
git commit -m "zfs: update OpenZFS base to zfs-2.5.0"
```

---

## Architecture

OpenZFS uses a clean platform-split model.  Each supported OS has its own
directory tree and no common code uses `#ifdef` guards for OS differences.

```
external/openzfs/
  include/os/
    linux/      -- Linux headers
    freebsd/    -- FreeBSD headers
    osv/        -- OSv headers (our patches)
  module/os/
    linux/      -- Linux implementation
    freebsd/    -- FreeBSD implementation
    osv/        -- OSv implementation (our patches)
```

### Key OSv Adaptations

| Concern | Approach |
|---------|----------|
| Memory management | `kmem_alloc()` / `kmem_free()` — no slab allocators |
| Reference counting | Manual `z_ref_cnt` (OSv lacks vnode refcounting) |
| Block I/O | `abd_borrow_buf()` + OSv bio layer (mirrors FreeBSD vdev_geom) |
| Threading | OSv threads wrapped as Solaris kthreads via SPL headers |
| Features not needed | zvol, encryption, xattrs, mandatory locks — stubbed out |

---

## Troubleshooting

### Patches do not apply cleanly

The submodule is not at the expected base tag.  Reset it:

```bash
git -C external/openzfs checkout zfs-2.4.1
./scripts/apply-openzfs-patches.sh
```

### "Already applied" prompt appears unexpectedly

The platform files exist but you need a clean re-apply.  Answer `y` to the
prompt, or reset manually:

```bash
git -C external/openzfs reset --hard zfs-2.4.1
git -C external/openzfs clean -fd
./scripts/apply-openzfs-patches.sh
```

### Build errors after applying patches

1. Check `bsd/sys/cddl/openzfs_sources.mk` for correct source lists.
2. Verify `Makefile` ICP assembly flags (see MEMORY.md for known issues).
3. Run `nm -u build/release.x64/libsolaris.so` to find undefined symbols.

---

## References

- OpenZFS documentation: <https://openzfs.github.io/openzfs-docs/>
- FreeBSD platform layer (closest reference): `external/openzfs/module/os/freebsd/`
- OSv mailing list: <osv-dev@googlegroups.com>
