#!/bin/bash
# Sequence editor for git rebase --interactive on osv-improvements-reorg-v2.
# Reorders the 68-commit history into 16 bucket commits.
#
# Strategy: pick buckets in dependency order. Within each bucket,
# pick first commit then fixup the rest, then exec to rewrite the
# message from .local/rebase/v2/NN-bucket.txt.
set -euo pipefail
cat > "$1" <<'EOF'
# === Bucket 1: build (NixOS toolchain + Boost) ===
pick b234155f build: add Nix flake for reproducible development environment
fixup 31c6a8fd build: update to latest Boost library
fixup 08ed8429 build: update Boost.Asio API for Boost 1.74+ compatibility
fixup 3d16b39a build: fix Boost 1.74+/1.78+ API compatibility in httpserver-api
fixup 5fde3f3b build: fix NixOS library resolution
fixup 8f9c9502 mmu: add missing #include <algorithm> for GCC 14 compatibility
fixup 69d1788f build: ignore .memelord/ memory database directory
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/01-build.txt

# === Bucket 2: libc (musl 1.2.1) ===
pick 688183a1 libc: upgrade musl from 1.1.24 to 1.2.1
fixup c8c5c255 libc: fix nftw uninitialized variable in musl 1.2.1
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/02-libc.txt

# === Bucket 3: mmu hugepages ===
pick 8c77d780 mmu: add MADV_HUGEPAGE and MAP_HUGETLB support
fixup a3531749 tests: add MAP_HUGETLB and MADV_HUGEPAGE functional tests to tst-huge
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/03-mmu-huge.txt

# === Bucket 4: mmu virt_to_phys ===
pick c275ee86 mmu: fix virt_to_phys for VMA-mapped DMA buffers
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/04-mmu-virtphys.txt

# === Bucket 5: shm ===
pick e3a328a1 shm: fix stale PTE bug, add POSIX shm and ftruncate support
fixup 953c4a96 tests: add shared memory consistency test
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/05-shm.txt

# === Bucket 6: pagecache ===
pick f8a0f5ce pagecache: add C-linkage helpers for ZFS vop_cache and GCC 14 fix
fixup 375598d2 pagecache: remove unreachable ARC bridge code, document design decision
fixup 55523197 pagecache: add sequential readahead and periodic writeback
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/06-pagecache.txt

# === Bucket 7: vfs fsync ===
pick 5270897a vfs: flush page cache before VOP_FSYNC in sys_fsync
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/07-vfs.txt

# === Bucket 8: block (must come before io_uring; io_uring touches blk-mq.cc) ===
pick dd8f9751 block: add TRIM/DISCARD and multiqueue I/O support
fixup 2acf2c58 bsd: fix device_delete_child return type
fixup 2894cffc scripts: add VirtIO-BLK multiqueue QEMU configuration
fixup e0e5f314 virtio-blk: implement per-CPU queue dispatch for multiqueue I/O
fixup 6d0d7d8c virtio-blk: fix per-queue locking race in multiqueue drain
fixup 23b3a148 block: remove unused next_queue_idx in blk-mq
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/09-block.txt

# === Bucket 9: io_uring ===
pick 124956b6 fs: implement io_uring async I/O interface
fixup 5720dc7c tests: fix io_uring test assertions; build: add zio_crypt to libsolaris
fixup c58ad1e5 tests: register tst-io_uring.so in modules/tests/Makefile
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/08-iouring.txt

# === Bucket 10: ci ===
pick 0d41fb93 ci: add Forgejo Actions workflows for Codeberg
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/10-ci.txt

# === Bucket 11: apps ===
pick 83d010ee build: point apps submodule at Codeberg fork with new demo apps
fixup 8714d10c apps: bump submodule pointer for cleanup commits
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/11-apps.txt

# === Bucket 12: zfs ===
pick a1ca7318 zfs: add OpenZFS 2.4.1 build system and Makefile integration
fixup fb1703ea zfs: implement OSv porting layer for OpenZFS 2.4.1 kernel module
fixup 4363efda zfs: integrate OpenZFS kernel module into OSv VFS and boot layer
fixup 4b7f8414 build: fix incremental rebuild with OpenZFS 2.4.1 objects
fixup 9d9e381c zfs: remove orphaned bsd/cddl legacy OpenSolaris userspace sources
fixup 8016f1e9 zfs: wire ZIO_TYPE_TRIM through vdev_disk to virtio-blk BIO_DISCARD
fixup 8ab7103d zfs: fix TRIM bio error mapping
fixup 54796e1a zfs: document real encryption impl; strengthen encryption test
fixup 2d2858a4 zfs: fix ARC shrinker, kthread stack, osv_free_pages, and memory pressure
fixup 10da9ff0 zfs: upgrade OpenZFS from 2.4.1 to 2.4.2
fixup fec4165f build: add external/openzfs to .gitmodules
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/12-zfs.txt

# === Bucket 13: java ===
pick fc08b26d zfs: fix symlink EBADF; build: fix binutils 2.46; java: NixOS compat fixes
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/13-java.txt

# === Bucket 14: tests ===
pick 4bd2b109 tests: add ZFS direct I/O validation test
fixup ea4f3d51 tests: add ZFS recordsize throughput benchmark
fixup 95acf03e tests: replace system() with libzfs API in ZFS test helpers
fixup 746d9fa1 tests: add ZFS encryption integration test
fixup 65e2a289 tests: add comprehensive filesystem performance benchmark
fixup 6059dce9 tests: update build manifests
fixup 1de0a1af images: add zfs-test image definition
fixup 9e0f9978 tests: add ZFS Crucible concurrent I/O stress test
fixup d080d717 tests: add ZFS database simulation benchmark
fixup f9d097aa tests: add ZFS TRIM/DISCARD test and cross-filesystem benchmark docs
fixup 0293d6d4 tests: fix uint64_t in tst-zfs-trim.cc
fixup 99ebc239 tests: fix ZFS TRIM test and db-sim pool size requirements
fixup d094b972 tests: make ZFS dataset tests idempotent; remove dead Rust scaffolding
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/14-tests.txt
exec git rm -f scripts/update-openzfs.sh 2>/dev/null; git rm -rf patches/openzfs 2>/dev/null; git diff --cached --quiet || git commit --amend --no-edit

# === Bucket 15: crucible ===
pick 981d5308 drivers: add Crucible distributed block storage driver
fixup 3d9b3950 drivers: add multi-volume Crucible support
fixup 77c3fb2b drivers: remove unused Rust stubs from Crucible
fixup 8b8a1490 drivers: harden Crucible block device driver
fixup f80260d5 build: make Crucible block device driver opt-in
fixup 1131e3a6 crucible: V13 wire-format compliance + threading + tests
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/15-crucible.txt

# === Bucket 16: docs ===
pick 7d2dc7f1 docs: update cover letter for Waldek
fixup f72eff82 docs: update cover letter -- remove NILFS2
fixup 3fc44018 docs: add sys_fsync page-cache flush fix to cover letter
fixup e1b9198f docs: remove COVER_LETTER.txt
fixup ab371dd0 docs: remove stale agent-generated status and example files
fixup 36694b7f docs: update cover letter with new stability fixes and benchmark results
fixup 3cab9d75 build: remove dead OpenZFS patch workflow
exec git commit --amend -F /home/gburd/ws/osv/.local/rebase/v2/16-docs.txt
EOF
