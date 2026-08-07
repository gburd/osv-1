# PR 7 - zfs: integrate OpenZFS 2.4.2 (TRIM, encryption, Direct I/O)

**Branch:** `gburd/osv-1:pr/openzfs` -> `cloudius-systems/osv:master`
**Base:** stacks on PR 6 (`pr/kernel-fixes`, 6e7213ae). Two-commit
branch: 3a020e20 (integration), f3614fd4 (tests).
**openzfs submodule:** our fork `codeberg.org/gregburd/zfs`, branch
`osv-2.4.2` (14 OSv platform commits on top of upstream `zfs-2.4.2`).
**Verified:** full `fs=zfs image=zfs-test` build on meh (GCC 14.3,
Boost 1.87), RC=0. Tests on the resulting image: tst-zfs-direct-io
(9/9), tst-zfs-trim (5/5), tst-zfs-encryption (21/21),
tst-shm-consistency (30/30), tst-zfs-multirec, tst-huge,
tst-zfs-recordsize bench, tst-zfs-db-sim (C1/C3/C4/C5).

---

## Title

zfs: replace zfs-on-osv with vendored OpenZFS 2.4.2

## Body

Replace OSv's bundled FreeBSD-derived ZFS port (zfs-on-osv, c. 2014,
last upstream sync ~2017) with a vendored OpenZFS 2.4.2: a fresh OSv
platform layer over the unmodified upstream OpenZFS kernel module,
plus userspace bindings (libzfs, libzfs_core, libzutil, libshare,
libuutil, libtpool) and the zpool/zfs CLIs.

### Build

- `external/openzfs/` submodule on the `osv-2.4.2` branch of our fork
  (14 OSv platform commits on top of upstream zfs-2.4.2), registered in
  `.gitmodules`.
- `bsd/sys/cddl/openzfs_sources.mk` drives the kernel-side compile,
  pulling in icp-asm and modes/. ASFLAGS uses `=` (not `+=`) so the
  older bsd/cddl `asm_linkage.h` does not win the include race.
- `openzfs-osv` source group consolidates OSv-specific helpers
  (zio_crypt stubs, taskq glue, opt_zfs_auto_upgrade, freemem,
  random_get_pseudo_bytes, the CDDL/BSD compat shim) into
  libsolaris.so so userspace tools resolve through the dynamic linker.

### VFS / boot integration

- vop_cache populates OSv's read_cache so userspace mmap/read reuse the
  same pages (uses the helpers from PR 3).
- va_fsid in zfs_vop_getattr taken from vp->v_mount->m_fsid.
- zfs_freesp + zfs_extend/zfs_free_range/zfs_trunc helpers so OSv
  ftruncate works on ZFS files.
- zfs_acl_ids_create stores file-type bits in z_mode, fixing EBADF on
  every ZFS symlink.
- ARC shrinker, kthread stack accounting, osv_free_pages, and
  memory-pressure callbacks reworked to match OSv's scheduler.

### Hardware features

- ZIO_TYPE_TRIM wired through vdev_disk to virtio-blk's BIO_DISCARD
  (PR 4). Enabled by default where the vdev advertises support; TRIM
  bio errors mapped to ENOTSUP (not EIO) for graceful fallback.
- AES-256-GCM encryption is the real OpenZFS implementation
  (zio_crypt_impl.c fully linked), not a stub. libzfs_crypto_os.c only
  stubs the userspace key-loading-from-passphrase path (ENOTSUP); raw
  and hex key formats work (tst-zfs-encryption 21/21).

### Cleanup

- Remove ~60k LOC of orphaned bsd/cddl OpenSolaris userspace sources
  the new build path no longer touches.

### Open gaps (disclosed for the maintainer)

1. **BSD-vs-OpenZFS performance not yet A/B-benchmarked.** Throughput
   is reasonable in tst-fs-bench but I have not produced a head-to-head
   number against the old zfs-on-osv port. The motivation is
   correctness/maintainability (12-year-old vs current upstream), not a
   perf claim.
2. **MAP_HUGETLB-backed ARC on aarch64 is untested.** The hugepage path
   (PR 2) is exercised on x86_64 only; ARM huge pages may need a
   separate pass.
3. **Loading a Linux-host-built ZFS image is not validated.** Images
   are built and booted on the same NixOS host; cross-host image
   portability (different zoneinfo/cert layout) is unverified.

### Notes

- Eighth in the series. Depends on PR 2 (mmu/shm), PR 3 (pagecache
  helpers), PR 4 (BIO_DISCARD). Related to upstream issue #1201 (the
  ask to relocate external/openzfs under /modules like lwext4) -- not
  done here; this PR vendors under external/ to minimize churn, and the
  /modules relocation can follow as a separate change.
