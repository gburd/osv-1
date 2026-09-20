# x86_64 CONFIRMATION: cross-address-space dlopen cache hit, no VMA in the faulting AS

2026-09-08. The aarch64 mechanism is **confirmed on x86_64**, deterministically, with
**no PostgreSQL, no ZFS, no ARC pressure, no HammerDB**. One bug across both ISAs and both
benchmark arms.

Base: osv `73a332f26` (`gh-fork/wip/pg-v26-faultfix`), apps `b38b99cd`
(`gburd/osv-apps` `wip/postgres18-musl-demo`). Built `conf_fork=1 image=tests fs=rofs`,
booted under qemu 8.1.3 with `-M pc -kernel loader.elf`, 4 vCPU / 4 GB.

Reproducer: `tests/tst-fork-xas-dlopen.cc` (in this directory). Fault arrives in
**under a second** after boot.

## The measurement that closes it

The probe reports, per address space and BEFORE any faulting dereference, whether the
object's `PT_DYNAMIC` VA is covered by a VMA. `mincore()` is the instrument: `core/mmu.cc`
`mincore()` consults `ismapped()` -> `find_intersecting_vmas()` -> `cur_vma_list()`, the
*same per-address-space vma list the page-fault slow path searches*, and returns ENOMEM
when no VMA covers the range.

    xas/child0-after-dlopen: base=0x10000002a000 PT_DYNAMIC=0x10000002edd8 VMA-in-this-AS=YES
    xas/child0: dlopen+dlsym OK in the AS that mapped it, fn_0(7)=7
    xas: child0 status=0x2a00
    xas/child1:              base=0x10000002a000 PT_DYNAMIC=0x10000002edd8 VMA-in-this-AS=NO
    xas/child1: cache hit maps NOTHING in this AS; next dlsym should fault
    xas/child1: calling dlsym now...
    page fault outside application, addr: 0x000010000002e000

Identical `_base` and `PT_DYNAMIC` in both address spaces; mapped in the one that loaded
it, **not mapped** in the one that got the cache hit. That is the mechanism stated as a
measurement rather than an inference.

## Fault signature vs. production

| | production (5 occurrences, 2 hypervisors) | this reproducer |
|---|---|---|
| RIP | `elf::object::dynamic_tag(unsigned int)+12` | `elf::object::dynamic_tag(unsigned int)+12` |
| backtrace | `page_fault+139 -> lookup_symbol_deep+29 -> dlsym+268` | identical |
| addr | page-aligned inside `program_base` | `0x000010000002e000` |
| cursor | `RAX` = fault_page + 0xda0 | `RAX = 0x10000002edd8` = fault_page + 0xdd8 |

`RAX` is `_dynamic_table`, i.e. the walk cursor in
`for (auto p = _dynamic_table; p->d_tag != DT_NULL; ++p)`. Both variants reproduce:

* `parent` mode: AS0 is the second consumer -> faults.
* `childb` mode: a LATER forked child is the second consumer (the PostgreSQL shape) -> faults.

## Controls

* **`probe` mode**: identical state, identical `VMA-in-this-AS=NO` report, but the faulting
  `dlsym()` is never called -> **no fault**. So the fault is the `_dynamic_table`
  dereference in the second AS, not the `dlopen` or the probe itself.
* **child0 always survives** its own `dlopen`+`dlsym`+call. The library is fine; only the
  *cross-AS cache hit* is broken.
* Reclaim is **not** involved: no ZFS in this image at all (`fs=rofs`), and ROFS sets
  `vop_cache = nullptr` (`fs/rofs/rofs_vnops.cc:359`), so `vfs_file::mmap` takes
  `default_file_mmap` -> `map_file_page_read` and library pages are private anonymous
  pages, never in `read_cache`/`arc_read_cache`.

## Why the earlier evidence pointed the wrong way

1. **The "exact page boundary" argument was a tautology.** `core/mmu.cc` `vm_fault()` does
   `addr = align_down(addr, mmu::page_size)` *before* the VMA lookup, and `vm_sigsegv()`
   prints that already-aligned value. Every slow-path "page fault outside application" is
   page-aligned for **any** cause. `RAX = page + 0xda0` was simply the true unaligned cursor.
2. **The aligned address actually proves it was NOT reclaim.** An aligned address implies the
   slow path, which implies `find_intersecting_vma_in(as->vmas, addr) == end()`: *no VMA
   covers the address*. Reclaim only clears PTEs (`cached_page::flush` -> `mmu::clear_pte`)
   and never removes a VMA; a cleared PTE under a live `file_vma` is serviced transparently
   by `vma->fault()` -> `populate_vma`. Pagecache reclaim of an ELF page is a demand-paging
   round trip, not a crash.
3. **The cited ARC lines cannot execute on this config.** Under `conf_zfs=openzfs`, patch
   0005 deliberately leaves `ZFS_ID` out of `m_fsid`, so `IS_ZFS()` is false,
   `arc_read_cache` is never populated, and `unmap_arc_buf` / `remove_arc_read_mapping` are
   unreachable (their only caller is `bsd/porting/mmu.cc:56 mmu_unmap()`, the legacy
   bsd_zfs path). Separately, `read_cache` has no LRU and no shrinker at all.
4. **The byte-identical address across 5 occurrences is positive evidence FOR this
   mechanism.** `_base` is frozen at first load, so every later backend is a cache hit on
   the same `_base`. A genuinely fresh `dlopen` per backend would advance `_next_alloc` and
   fault at a different address each time; reclaim would not produce a fixed address across
   fresh boots.
5. **Why the two negative reproducers passed.** `dlrace` (582M dlsym / 5.6M dlopen) and
   `dlrace2` (640 forks) both exercised dl *concurrency*, but the fault needs a **cache hit
   from a different AS than the one that mapped the segments**. Neither ever arranged that:
   in `dlrace` all activity is in one AS, and in `dlrace2` each child loads for itself.
   The negatives are what prove the mechanism requires the cross-AS cache hit rather than
   mere concurrency.
6. **ARC pressure was incidental**, affecting only the timing of *which* backend loaded
   plpgsql first, not causal. The discriminator table therefore does not carry the weight
   originally claimed.

## Mechanism in source terms

* `program_base = 0x100000000000` (`include/osv/elf.hh:568`) is **PML4 slot 32**, and
  `clone_address_space()` clones only app slots 1..127 per child, so shared-library
  mappings are **per-address-space**.
* `mmu::map_file` -> `allocate()` inserts the `file_vma` into
  `cur_vma_list() == current_address_space()->vmas`, i.e. the AS of whichever thread ran the
  loader.
* `elf::program`'s object cache (`_files`, the RCU `_modules` list) is process-**global**,
  and the cache-hit return in `program::load_object()` contains **no reference to any
  address space**: it returns the cached object without mapping anything.
* `_dynamic_table = _base + PT_DYNAMIC.p_vaddr` (`core/elf.cc:530`) is therefore a VA valid
  only in the loader's AS. `dlsym` -> `lookup_symbol_deep` -> `lookup_symbol` ->
  `dynamic_ptr(DT_SYMTAB)` -> `_dynamic_tag` dereferences it in the wrong AS.

The existing `fork_share_dlopen` mitigation shares RO/exec **PTEs** at
`clone_address_space()` time, so it helps children forked *after* the load and does nothing
for a sibling or parent AS that dlopens later.

## Aftermath (methodology)

`vm_sigsegv()` calls `abort()` from inside the fault handler while `vmas_mutex` is held, so
fork/mmap wedge permanently: the guest keeps burning CPU and logging while the network goes
deaf and "autovacuum worker took too long to start" repeats forever. A naive harness records
"connection refused" and blames the network. Full console capture and an independent connect
probe are mandatory instruments.

## Handoff

Fix is owned by the aarch64 agent (541f3862) and belongs on the fork branch, to be reported
on **#1456** (the PR carrying `fork.cc`). `upstream/master` has no `fork()`
(`git show upstream/master:core/mmu.cc | grep -c 'CONF_fork\|clone_address_space'` = 0), is
single-address-space, and therefore cannot exhibit this bug: **there is no standalone
upstream/master PR to open for it.** No fix was written here, and the pagecache/reclaim path
was deliberately **not** hardened: confirmed non-bug.

Framing stays generic: any application that forks and then dlopens the same library from
more than one address space can hit this. PostgreSQL merely makes it trivial, since every
backend is a fork that dlopens plpgsql.
