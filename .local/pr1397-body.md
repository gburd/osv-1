Five memory-management fixes that the later ZFS and Crucible work
depends on. Each is independent and self-contained.

This bases directly on current master (623ff90e); the build-compat and
musl 1.2.1 PRs that preceded it in the series are already merged.

### Changes

- **mmu: add MADV_HUGEPAGE and MAP_HUGETLB**. Implement the two Linux
  hugepage hint APIs against OSv's existing 2 MiB transparent-hugepage
  support. `madvise(MADV_HUGEPAGE)` records the hint on the VMA;
  `mmap(... MAP_HUGETLB ...)` allocates directly from the huge-page
  pool (ENOMEM rather than silent small-page fallback). OSv's
  huge_page_size is 2 MiB and the MAP_HUGE_2MB / MAP_HUGE_1GB
  size-selector bits are not decoded, so MAP_HUGETLB always maps with
  2 MiB pages regardless of any size hint.

- **mmu: fix virt_to_phys for VMA-mapped DMA buffers**.
  `virt_to_phys()` was correct only for kernel-direct-mapped
  addresses; on a VMA-mapped buffer it returned the linear-mapping
  offset rather than the page frame, producing silent DMA corruption.
  Walk the page tables and return the PTE's physical frame, keeping
  the direct-map fast path. Underlying cause of intermittent
  virtio-blk / Crucible DMA misalignment.

- **mempool: guard l2::refill against mid-batch allocation failure**.
  `l2::refill()` fills a page_batch with nr_pages calls to
  `free_page_ranges.alloc()`, then reuses the last page as the batch
  header. Under memory pressure alloc() can return nullptr; the old
  loop ignored that, turning a failed last slot into a null-header
  write and a failed earlier slot into a later fault. Check every
  iteration, stop at the first failure, return the partial pages, and
  account only for what was actually allocated.

- **shm: fix stale PTE bug, implement POSIX shm and ftruncate**.
  `shm_file::put_page()` returned without clearing the PTE on reuse,
  so a fresh SHM segment could read the previous tenant's data. Clear
  the PTE before returning false (false keeps the TLB-gather path from
  freeing the page; `shm_file::close()` owns it). Implements the rest
  of the POSIX shm surface the fix exposed: shm_open/unlink,
  shmctl(IPC_STAT), shm_file::truncate (sys_ftruncate now delegates to
  fp->truncate() for dentry-less files).

- **mmu: fix in_vma_range to use debug_base after mem_area refactor**.
  The mem_area refactor moved debug memory to a positive base; the old
  `addr >= 0` predicate then matched every normal allocation, firing
  vpopulate's assert on the first debug allocation and making
  conf_debug_memory unbootable. Discriminate on debug_base.

### Verified

Kernel compiles and links clean on GCC 14.3 / Boost 1.87 (fresh
loader.elf, RC=0). tst-shm-consistency (30/30) and tst-huge PASS on
the ZFS image (the test sources are carried by the openzfs PR later in
the series; the kernel-side APIs land here).
