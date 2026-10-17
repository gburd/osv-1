# lwext4 fork review + OSv roadmap status (2026-10-16)

Copyright (c) 2026 Greg Burd. BSD-3-Clause.

## 1. Aladdin-R-D/lwext4 review

Fork https://github.com/Aladdin-R-D/lwext4 is 18 commits ahead of gkostka upstream
(58bcf89a1, dormant since 2022-09): 8 code fixes + merges/README/SECURITY docs. All 8 are
memory-safety hardening on crafted/corrupt images. License is lwext4's own (BSD-ish), compatible.

Our existing ext4 hardening: #1449 (ext_readlink/readdir heap overflow) and #1533 (extent-header
+ superblock block-size validation, backporting gkostka PRs #107/#111 by Chris Thomas), carried as
modules/lwext4/patches/0001-validate-ext4-headers.patch on osvunikernel/lwext4 @ 6f6d8f7c5.

Per-fix verdict (checked against #1533 and the osvunikernel read path):

| Aladdin fix | file | verdict |
|---|---|---|
| 1181cc7ba OOB read ext4_ext_binsearch_idx | ext4_extent.c | SKIP. Largely covered: read_extent_tree_block() already calls ext4_ext_check() per walked block, and #1533 strengthens ext4_ext_check to bound eh_max by buffer capacity. Marginal defense-in-depth; adds divergence. |
| 1d32b2f17 NULL guard ext4_dir_en_get_name_len | ext4_dir.h | TAKE. Cheap, in the untrusted dir-read path, not in #1533. |
| 1a58d2275 FPE ext4_block_set_lb_size (bsize bounds in mount) | ext4.c | SKIP. Redundant with #1533's log_block_size>6 reject (the canonical spot, in ext4_sb_check). |
| 2f5714d42 OOB WRITE ext4_bmap_bit_set (bitmap init bounds) | ext4_fs.c | TAKE (highest value). A real out-of-bounds write when bit_max/inodes_per_group from a crafted group descriptor exceed the block buffer. Not covered by #1533. Fix the odd error codes (ENXIO/EFAULT -> EIO). |
| ae525c386 Double-Free ext4_bcache_drop_buf | ext4_bcache.c | DO NOT TAKE. Its own comment says "Needs to be tested carefully! Potentially not safe!" It force-zeros refctr and RB_REMOVEs a still-referenced buffer -> potential use-after-free. Papers over the double-free by creating a UAF. The real double-free needs the dropping caller fixed, not this. |
| 30aa26c7e NULL guard mp __ext4_trans_start | ext4.c | SKIP. Callers already hold a valid mp. |
| eb2cb0b26 NULL guard orig_path ext4_find_extent | ext4_extent.c | MARGINAL. Callers always pass a valid path. Take only if bundling. |
| fa299459e div-by-zero create_fs_aux_info | ext4_mkfs.c | TAKE. Cheap, real (block_size 0). mkfs path; low severity for us (we control mkfs input) but correct. Fix code ENOMEM -> EINVAL. |

Clear TAKE set: 2f5714d42 (bitmap OOB write), 1d32b2f17 (dir NULL guard), fa299459e (mkfs
div-by-zero). The standout is the bitmap OOB write.

## 2. Other lwext4 forks (surveyed 40 forks pushed since 2024)

Two forks are far richer sources than Aladdin-R-D:

- **antimatter-studios/lwext4** (pushed 2026-10-17, 482 commits ahead, BSD license). A seriously
  maintained hardening fork: journaling (commit/revoke/checkpoint/recover I/O-error handling),
  extent depth/byte-order, htree split allocation, xattr (ibody/extra-isize/alignment), slow and
  fast symlink read/write, multi-thread lock fixes (readlink nested lock, bdif ph/bbuf lock),
  plus a real test suite (memory/leak/fragmentation, mt-stress, partitions, fuzzing). PR numbers
  run to #212. Its readlink-nested-lock and xattr fixes OVERLAP our #1449 and the ext4 security
  work, and its journal fixes bear on our deferred journaling (D2.1). This is the fork to mine
  if we invest further in ext4 robustness. It developed the extent-depth and journal-block-size
  fixes independently of the gkostka #107/#111 our #1533 backports.
- **extremscorner/lwext4** (2026-03, 17 commits, BSD): concrete correctness fixes - O_EXCL,
  sparse-file write without extents, metadata_csum_seed, big-endian checksum type check, dir_idx
  csum init. Useful if we need those features/correctness; several are write-path (D2.2 territory).

Most other active forks are OS ports (Starry-OS, twizzler, Wii-Linux, yasos/matgla, oscomp,
mcu/Alfa) carrying their own platform glue, not general fixes of value to us.

## 3. Recommendation

- Carry the vetted subset (2f5714d42 + 1d32b2f17 + fa299459e, credited to Aladdin-R-D) as a new
  patch modules/lwext4/patches/0002-*.patch, in the same model as #1533's 0001. Add it as a
  second commit on #1533 (or a sibling PR), since #1533 is already the ext4-image-hardening PR.
- The real upstream (gkostka) is dormant since 2022-09, so "propose upstream" means a gkostka
  PR/issue that may never land (we already reference #107/#111 there). We carry regardless.
- Bigger opportunity: evaluate antimatter-studios/lwext4 as a candidate base for a future ext4
  hardening/journaling pass (D2.1), rather than one-off cherry-picks. It is where the active
  lwext4 robustness work now lives. This is a larger decision for a dedicated session.
- DO NOT take Aladdin's double-free "fix" (ae525c386); it risks a UAF.

## 4. OSv roadmap status (approved scope B1-E1 + D-series)

FINISHED (merged into upstream master 872f606b7, verified in git log):
- OpenZFS keystone (conf_zfs=bsd|openzfs), ld-musl soname loader, close_range(2), setrlimit,
  libaio (C1, the former crash landmine - now a real io_uring-backed impl), NUMA topology
  discovery from ACPI SRAT/SLIT (a92c44f9b), the random harvest-queue fix.

OPEN as PRs, validated, waiting on the maintainer (merge button is @nyh):
- C-series syscalls: #1439 signalfd (C9), #1440 inotify (C8). mremap/splice/membarrier/prctl/
  renameat2/copy_file_range exist in-tree from earlier rounds (confirm each has a live PR row).
- D1 IPv6: #1442 (forward-port) + #1444 (checksum/TSO offload), stacked. #1442 is BLOCKED in the
  readiness audit (carried IPv6-independent).
- D2 ext4: #1449 (readlink/readdir overflow), #1533 (extent/sb validation), #1500 (pin commit),
  #1510 (sequential-read perf: read-ahead + async prefetch) - DRAFT.
- NUMA B2: #1438 (getcpu/get_mempolicy real topology), #1441/#1445 (per-node L1/L2 pools), #1482
  (bound SRAT/SLIT parsing).
- Fork trilogy: #1455 (thread-backed fork, opt-in), #1456 (per-child COW AS), #1475 (lock-free
  nested COW fault). #1458 is the DO-NOT-MERGE tracking draft.
- Locale (NEW, just completed this campaign): #1477 (strict C/C.UTF-8), #1555-#1559
  (named locales, LC_NUMERIC, LC_COLLATE, gettext, locale-data module); osv-apps #74 (ICU),
  #75 (PostgreSQL --with-icu, draft on fork/COW).
- Crucible: #1424 (draft).

HALF-FINISHED / deferred-by-design:
- D2.1 ext4 journaling: NOT implemented (libext comment "does not implement journal ... integrate
  it later and make it optional"). antimatter-studios has journal fixes to mine.
- D2.2 ext4 write-path performance / zero-copy pagecache bridge (reuse the ZFS ARC bridge): the
  pagecache bridge "can come later if it shows up hot" (ext_vnops.cc:1953); block allocation is
  "a rather very naive implementation which eagerly allocates" (ext_vnops.cc:1390).
- B1 Azure/Hyper-V (VMBus/netvsc/storvsc/gen2 boot): not started; needs an Azure burner.
- B3 CPU/mem hot-plug: virtio-balloon path only; true ACPI/HV hot-add deferred.
- B4 GPU/accelerator (VFIO/passthrough/SR-IOV): not started (spike B4.1 first).
- D4 RDMA/DPDK/AF_XDP: not started (AF_XDP first).
- E1 deep security audit: last, after B/C/D.
- Benchmark/perf causality: the PG scaling cliff and idle-host wedge remain UNRESOLVED and not
  root-caused (per the standing corrections); do not claim diagnosis complete.

DROPPED: D3 NTFS (owner decision 2026-07-12). Tier-0 fork/exec/clone-proc/ptrace: will not do.

## 5. Incomplete-work markers in OUR code (master, excluding musl submodule)

Totals: 160 TODO, 97 FIXME, 5 XXX (257), plus UNIMPL/stub/ENOSYS honest rejections. By area:
core 72, drivers 39, drivers/libtsm 37 (vendored terminal lib), libc 28, arch/x64 18,
include/osv 12, fs/virtiofs 10, arch/aarch64 9, fs/vfs 8, fs/rofs 7.

The ones that are genuine OSv feature gaps (not vendored noise):
- fs/vfs/main.cc: fcntl F_SETLK/F_GETLK/F_SETLKW/F_SETOWN stubbed (WARN_ONCE); faccessat()
  AT_SYMLINK_NOFOLLOW UNIMPLEMENTED; a path returning ENOSYS. (#1530 improves F_GETLK.)
- modules/libext/ext_vnops.cc (D2): no journaling (:19); naive eager block allocation (:1390);
  deferred fsid (:1719); no ARC-style pagecache bridge yet (:1953); dtime-on-delete handled (:74).
- libc/signal.cc: sigsuspend UNIMPL.
- libc/pthread.cc: _pthread_cleanup_push/pop are no-op stubs (:1264-5, "TODO check if ok").
- libc/dlfcn.cc: dlvsym stubbed (ignores version).
- libc/random.c: GRND_NONBLOCK not honored.
- core/io_uring.cc: multishot variants, SQE128 geometry not implemented (honest rejections).
- drivers/nvme-queue.cc, nvme.cc, scsi-common.cc: assorted "not implemented" branches (PRP list
  >1 page; REPORT LUNS).
- libc/stdlib/unimplemented.cc: float128 strto/strfrom (UNIMPL).
Most core/arch/driver TODOs are optimisation notes or edge-case markers, not missing features;
drivers/libtsm's 37 are in a vendored library.
