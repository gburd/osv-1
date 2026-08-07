# PR 2 - mmu/shm: hugepage hints, virt_to_phys, POSIX shm, in_vma_range

**Branch:** `gburd/osv-1:pr/mmu-shm` -> `cloudius-systems/osv:master`
**Base:** stacks on PR 1 (`pr/musl`, 9a41e781), which stacks on PR 0
(`pr/build-compat`, fa343f2a). Four-commit branch:
5128a43f, 9596012a, 14124fe0, 387a97de.
**Verified:** kernel compiles + links clean on GCC 14.3 / Boost 1.87
(`./scripts/build fs=rofs image=empty`, fresh loader.elf, RC=0).
tst-shm-consistency (30/30) and tst-huge PASS on the ZFS image (carried
by the openzfs PR later in the series).

---

## Title

mmu/shm: hugepage hints, VMA virt_to_phys, POSIX shm, in_vma_range fix

## Body

Four memory-management fixes that the later ZFS and Crucible work
depends on. Each is independent and self-contained.

### Changes

- **mmu: add MADV_HUGEPAGE and MAP_HUGETLB** (5128a43f). Implement the
  two Linux hugepage hint APIs against OSv's existing 2 MiB / 1 GiB
  page support. `madvise(MADV_HUGEPAGE)` records the hint on the VMA;
  `mmap(... MAP_HUGETLB ...)` allocates directly from the huge-page
  pool (ENOMEM rather than silent small-page fallback), honouring
  MAP_HUGE_2MB / MAP_HUGE_1GB.

- **mmu: fix virt_to_phys for VMA-mapped DMA buffers** (9596012a).
  `virt_to_phys()` was correct only for kernel-direct-mapped
  addresses; on a VMA-mapped buffer it returned the linear-mapping
  offset rather than the page frame, producing silent DMA corruption.
  Walk the page tables and return the PTE's physical frame, keeping
  the direct-map fast path. Underlying cause of intermittent
  virtio-blk / Crucible DMA misalignment.

- **shm: fix stale PTE bug, implement POSIX shm and ftruncate**
  (14124fe0). `shm_file::put_page()` returned without clearing the PTE
  on reuse, so a fresh SHM segment could read the previous tenant's
  data. Clear the PTE before returning false (false keeps the TLB-gather
  path from freeing the page; `shm_file::close()` owns it). Implements
  the rest of the POSIX shm surface the fix exposed: shm_open/unlink,
  shmctl(IPC_STAT), shm_file::truncate (sys_ftruncate now delegates to
  fp->truncate() for dentry-less files).

- **mmu: fix in_vma_range to use debug_base after mem_area refactor**
  (387a97de). The mem_area refactor moved debug memory to a positive
  base; the old `addr >= 0` predicate then matched every normal
  allocation, firing vpopulate's assert on the first debug allocation
  and making conf_debug_memory unbootable. Discriminate on debug_base.

### Notes

- Third in the build/libc modernization series (PR 0 -> musl -> this).
- tst-huge and tst-shm-consistency are added/exercised by later PRs in
  the series (they share the ZFS test image); the kernel-side APIs
  land here.
