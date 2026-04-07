# OSv ZFS Patch System

This directory documents all OSv-specific modifications to the ZFS
codebase in `bsd/sys/cddl/contrib/opensolaris/`. These modifications
are needed to integrate ZFS with OSv's unikernel architecture, which
lacks many FreeBSD kernel subsystems.

## Structure

- `manifest.json` - Machine-readable inventory of all modifications
  with file paths, patch names, types, and descriptions.
- `INTEGRATION.md` - Detailed documentation of the ZFS-OSv integration
  architecture: initialization, callbacks, VFS hooks, memory management.
- `patches/` - Individual patch files for each logical modification group.

## Modification Types

- **complete_rewrite** - File is entirely replaced with OSv-specific code
- **conditional_compilation** - Uses `#ifdef __OSV__` / `#ifndef __OSV__`
  guards for targeted changes within the original file
- **osv_specific** - File exists only in OSv, not in upstream ZFS

## File Inventory

22 files in `bsd/sys/cddl/contrib/opensolaris/` contain `__OSV__` guards,
plus 1 OSv-specific file (`fs/zfs/zfs_initialize.c`).

See `manifest.json` for the complete list with descriptions.

## Purpose

This patch system serves two goals:

1. **Documentation** - Understand what OSv changes vs upstream ZFS and why
2. **Portability** - When updating to a newer OpenZFS, these patches
   identify what must be re-applied or re-implemented
