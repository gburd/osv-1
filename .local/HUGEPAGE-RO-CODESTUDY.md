# Hugepages-hurt-OSv-RO code study - hypothesis for the metal profiler (LOCAL, no EC2)

Copyright (C) 2026 Greg Burd

FACT (ZFS-MATRIX-QEMU.md): hugepages HURT OSv RO markedly (c8 24627->18682 = -24%, c64
21238->15404 = -27%) and are NEUTRAL for Linux RO. RW ~neutral on both. The matrix "hpON" cell
set BOTH (a) PG `huge_pages=on` (guest allocates shared_buffers on 2MB pages) AND (b) qemu
`-mem-path /dev/hugepages -mem-prealloc` (guest RAM backed by host 2MB pages). We want WHY, and
whether the fix is config or code.

## The OSv hugepage paths that matter

- Anon large-page allocation: `memory::alloc_huge_page(2MB)` (core/mempool.cc:2054) takes the
  **GLOBAL `free_page_ranges_lock`** and does `alloc_aligned(N, 0, N, true)` - a scan for a
  2MB-aligned contiguous run. Level-1 map: core/mmu.cc:1819-1821.
- COW-fork clone of a writable 2MB page: `clone_pt_level<1>` (core/mmu.cc:429-460). See H1.

## RANKED HYPOTHESES (most-likely first)

### H1 (TOP) - PG huge_pages=on FIGHTS OSv's COW fork: every forked backend SPLITS the whole
###           shared_buffers arena back to 4K in the parent, so OSv gets the split cost with NONE
###           of the TLB benefit.
`core/mmu.cc:442-449` (clone_pt_level<1>): a WRITABLE 2MB large page "must NOT be shared as-is ...
Split it to 4 K in the PARENT in place, then fall through to the normal 4 K clone path." PG's
shared_buffers is a WRITABLE large ANON mapping (MAP_SHARED|MAP_ANON via sysv-shm/mmap). On the
FIRST postmaster fork of a backend, clone_pt_level<1> walks the shared-mem arena and, for every
2MB PTE, calls `split_large_page` in the PARENT - permanently demoting the ENTIRE shared_buffers
arena from 2MB pages to 512x 4K pages. After that:
- The TLB win that was the ONLY reason to turn hugepages on is GONE (the arena is 4K-mapped
  again), so RO gains nothing.
- But OSv already PAID: the split (allocate a 4K page-table per 2MB region, populate 512 PTEs),
  and now every backend clones 512 PTEs per 2MB instead of one large PTE = a bigger, slower fork
  and a fatter page table (more page-walk / cache footprint per backend).
- Net: cost with no benefit => the -24-27% RO regression. This is UNIQUE to OSv's fork model;
  Linux keeps hugepages as real 2MB shared pages across fork (shared, not split), so Linux is
  neutral. THAT asymmetry is exactly the observed OSv-hurts / Linux-neutral split.
WHY IT HITS RO SPECIFICALLY: RO is CPU/dispatch-bound with a tight per-query path; a fatter page
table + lost TLB coverage on the hot shared_buffers arena raises per-access cost on the exact hot
path. RW is fsync/WAL-bound (I/O dominated) so the page-table overhead is proportionally hidden =
matches "RW ~neutral, RO -24-27%."
CONFIRM ON METAL: after PG reaches ready + forks its first backend with huge_pages=on, dump the
shared_buffers arena's page size (are the PTEs still 2MB, or split to 4K?). If split -> H1
confirmed. Also compare fork latency huge_pages on vs off.
FIX = **CONFIG, not code**: run OSv PG with `huge_pages=off` (ZFS-MATRIX-QEMU already recommends
this). The guest-side PG hugepage arena is a net loss under OSv's split-on-fork COW. A CODE fix
(teach clone_pt_level<1> to keep a writable MAP_SHARED 2MB page shared+large across fork instead
of splitting) is possible but bigger and risky (it is the fork-COW correctness path); defer.

### H2 - qemu -mem-prealloc on hugetlbfs = a one-time boot cost mis-attributed, PLUS host 2MB
###      backing changes guest-physical fragmentation (LOW-MEDIUM)
`-mem-prealloc` faults in all guest RAM at boot on 2MB host pages. That is a BOOT cost, not a
per-query cost, so it should not lower steady-state tps - UNLESS the run's warmup did not fully
absorb it. More plausibly: backing guest RAM with host 2MB pages changes how OSv's own
`alloc_huge_page` finds 2MB-aligned contiguous runs (core/mempool.cc:2056 alloc_aligned under the
global lock). If host-hugepage backing makes OSv's guest-physical layout such that its own
2MB-page allocations succeed MORE often (for ARC buffers, malloc>2MB), OSv ends up using more
internal 2MB pages that then hit the same split-on-fork / management cost. Rank LOW-MEDIUM;
secondary to H1. CONFIRM: run the A/B with PG huge_pages=on but qemu WITHOUT -mem-path (guest 2MB
PG arena, host 4K backing). If the -24% persists -> it is H1 (guest PG arena), not the host
backing -> isolates the two.

### H3 - global free_page_ranges_lock contention on 2MB allocation (LOW)
`alloc_huge_page` holds the GLOBAL `free_page_ranges_lock` while scanning for an aligned run
(core/mempool.cc:2056). Under concurrent forking backends each allocating/splitting 2MB regions,
this serializes. But steady-state RO after warmup does few new 2MB allocations, so this is a
fork-time cost, not the steady RO ceiling. Rank LOW; a contributor to fork latency, folded into
H1's "fatter/slower fork."

### H4 - ARC buffers on hugepages (RULED LOW by the read-path study)
Per zfs_vop_cache (ZFS-READPATH-CODESTUDY.md), OpenZFS-on-OSv reads route through the read_cache
with a per-page copy, and the ARC keeps its own buffers - it does not place the pgbench working
set on the guest PG hugepage arena. So the RO regression is not "ARC on hugepages"; it is the PG
shared_buffers arena (H1). Rank LOW.

## VERDICT + guidance
- Most-likely cause = H1: PG huge_pages=on is actively counter-productive under OSv's
  split-writable-2MB-on-COW-fork, giving the split/fatter-page-table cost with no retained TLB
  benefit. Linux keeps the pages shared+large across fork, hence neutral.
- It is a **CONFIG fix**: run OSv PG-on-ZFS with `huge_pages=off` (already the ZFS-MATRIX
  recommendation). No code change needed for the deployment story.
- A code fix EXISTS in principle (share writable MAP_SHARED 2MB pages large across fork rather
  than split), but it touches the fork-COW correctness path (the same machinery behind the
  historical fork crashes) - high risk, low payoff vs just disabling PG hugepages. Deferred.
- Metal profiler, cheapest decisive check: after first backend fork with huge_pages=on, is the
  shared_buffers arena still 2MB-mapped or split to 4K? Split => H1. Then the A/B in H2 (guest
  hugepages, host 4K backing) isolates guest-PG-arena vs host-backing.
