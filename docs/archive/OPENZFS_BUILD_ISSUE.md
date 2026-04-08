# OpenZFS Build Issue - Agent 7 Finding

## Problem

Build fails with compilation error:

```
external/openzfs/module/os/osv/zfs/spl_uio.c:47:31: error: 'UIO_NOCOPY' undeclared (first use in this function)
   47 |         zfs_uio_segflg(uio) = UIO_NOCOPY;
      |                               ^~~~~~~~~~
external/openzfs/module/os/osv/zfs/spl_uio.c:49:29: error: lvalue required as left operand of assignment
   49 |         zfs_uio_segflg(uio) = segflg;
      |                             ^
```

## Root Cause

In `/home/gburd/ws/osv/external/openzfs/include/os/osv/spl/sys/uio.h`, line 70:

```c
#define	zfs_uio_segflg(u)	ZFS_UIO_SYSSPACE
```

This macro expands to a **constant**, not an lvalue. You cannot assign to it.

In `/home/gburd/ws/osv/external/openzfs/module/os/osv/zfs/spl_uio.c`, lines 46-49:

```c
zfs_uio_seg_t segflg = zfs_uio_segflg(uio);
zfs_uio_segflg(uio) = UIO_NOCOPY;         // ERROR: Cannot assign to constant
zfs_uiomove(NULL, n, zfs_uio_rw(uio), uio);
zfs_uio_segflg(uio) = segflg;             // ERROR: Cannot assign to constant
```

## Comparison with FreeBSD

FreeBSD's version (`external/openzfs/include/os/freebsd/spl/sys/uio.h:65`):

```c
#define	zfs_uio_segflg(u)	GET_UIO_STRUCT(u)->uio_segflg
```

This expands to a **field access** (lvalue), so assignment works.

FreeBSD also has `UIO_NOCOPY` defined in their uio.h headers.

## Why OSv is Different

OSv is a unikernel with no user/kernel space distinction. The segment flag is meaningless and hardcoded to `ZFS_UIO_SYSSPACE`. Therefore:

1. `UIO_NOCOPY` doesn't exist (and isn't needed)
2. `zfs_uio_segflg()` is read-only

## Solution

Fix `/home/gburd/ws/osv/external/openzfs/module/os/osv/zfs/spl_uio.c` line 40-50:

**Current (broken) code:**

```c
void
zfs_uioskip(zfs_uio_t *uio, size_t n)
{
	if (n > zfs_uio_resid(uio))
		return;

	zfs_uio_seg_t segflg = zfs_uio_segflg(uio);
	zfs_uio_segflg(uio) = UIO_NOCOPY;
	zfs_uiomove(NULL, n, zfs_uio_rw(uio), uio);
	zfs_uio_segflg(uio) = segflg;
}
```

**Fixed code:**

```c
void
zfs_uioskip(zfs_uio_t *uio, size_t n)
{
	if (n > zfs_uio_resid(uio))
		return;

	/*
	 * OSv is a unikernel with no user/kernel space distinction.
	 * UIO_NOCOPY optimization is not applicable. Just advance the uio.
	 */
	zfs_uiomove(NULL, n, zfs_uio_rw(uio), uio);
}
```

## Rationale

The `UIO_NOCOPY` flag in FreeBSD is an optimization to skip actual data copying when the kernel already has access to the buffers. In OSv:

- There's no user/kernel boundary
- All memory is directly accessible
- The segment flag is always `ZFS_UIO_SYSSPACE`
- The optimization doesn't apply

Simply calling `zfs_uiomove(NULL, n, ...)` will advance the uio structure correctly.

## Testing

After this fix, build with:

```bash
./scripts/build fs=zfs image=empty
```

Verify no compilation errors.

## Files Fixed

### 1. `/home/gburd/ws/osv/external/openzfs/module/os/osv/zfs/spl_uio.c`
- **Lines:** 40-50 (function `zfs_uioskip`)
- **Status:** ✅ FIXED (already done by another agent)

### 2. `/home/gburd/ws/osv/external/openzfs/module/os/osv/zfs/zfs_ctldir.c`
- **Issue:** Function `zfsctl_snapshot_unmount` declared as `void` but header expects `int`
- **Status:** ✅ FIXED (line 13-17)

## New Issues Found

### 3. `/home/gburd/ws/osv/external/openzfs/module/os/osv/zfs/zfs_dir.c`

Multiple function signature mismatches:

1. **Line 43:** `zfs_grow_blocksize`
   - Implementation: `int zfs_grow_blocksize(...)`
   - Header expects: `void zfs_grow_blocksize(...)`

2. **Line 80:** `zfs_cmpldev`
   - Implementation: `void zfs_cmpldev(uint64_t dev, uint32_t *m)`
   - Header expects: `dev_t zfs_cmpldev(uint64_t)`

3. **Line 89:** `zfs_create_fs`
   - Implementation: `int zfs_create_fs(...)`
   - Header expects: `void zfs_create_fs(...)`

4. **Line 134:** Missing function `zfs_sa_setup`
   - Function not declared/implemented

These indicate the OSv port is incomplete and needs systematic fixes to match the OpenZFS API.
