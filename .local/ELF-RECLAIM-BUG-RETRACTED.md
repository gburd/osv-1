# RETRACTED 2026-09-08: the "CONFIRMED" mechanism in this file is WRONG

**Do not act on or quote the mechanism below.** Agent 0261152a refuted it at source level
before implementing the fix I briefed, and I verified all three of its claims. The fault is
real and reproducible; **my explanation of it was not.** Kept for the record because the
reasoning error is instructive.

## Why my "clinching arithmetic" proved nothing

I argued that the fault landing on an **exact page boundary** with the cursor mid-page proved
a page-granular event (i.e. reclaim). It proves nothing:

    core/mmu.cc:2457   addr = align_down(addr, mmu::page_size);   <- BEFORE the VMA lookup
    core/mmu.cc:2345   vm_sigsegv() prints that already-aligned addr

**Every** slow-path "page fault outside application" is page-aligned, for any cause. And
`RAX = fault_page + 0xda0` is just the true unaligned cursor (`_dynamic_table` around
`0x100000f46da0`). Both numbers are exactly what a plain first-deref of an unmapped
`_dynamic_table` yields. **I presented a derived constant as independent evidence.** That is a
reasoning error, not a slip: the "byte-identical across 5 occurrences" observation is real and
still interesting, but it is consistent with any deterministic bad pointer, not specifically
with reclaim.

## Why the aligned address actually RULES OUT reclaim

There are two routes to `vm_sigsegv`: the fast path (`fast_sigsegv_check`, which prints the
RAW address) and the slow path (VMA lookup failed). We saw an ALIGNED address, therefore the
**slow path**, therefore `find_intersecting_vma_in(as->vmas, addr) == end()` - **no VMA covers
the address in the faulting AS.**

But reclaim only CLEARS PTEs (`core/pagecache.cc:229/296` `mmu::clear_pte`, `:397`
`cp->unmap(ptep)`); it **never removes a VMA**. A cleared PTE under a live `file_vma` is
serviced transparently by `vma->fault()` (`core/mmu.cc:2511`) which re-reads from the file.
**Pagecache reclaim of an ELF page is a demand-paging round trip, not a crash.** The fix I
designed would have hardened a non-bug.

## And the ARC path I cited cannot even execute on this config

`modules/open_zfs/patches/0005` deliberately removes `ZFS_ID` from `m_fsid`, so `IS_ZFS()` is
**false** under `conf_zfs=openzfs`, `arc_read_cache` is never populated, and
`unmap_arc_buf`/`remove_arc_read_mapping` are unreachable. Their only caller is
`bsd/porting/mmu.cc:56 mmu_unmap()`, the legacy **bsd_zfs** libsolaris path. I cited specific
line numbers in code that does not run in the configuration under test.

## What survives, and what does not

SURVIVES: the fault itself (5 occurrences, byte-identical address, QEMU-KVM and Firecracker);
the zombie aftermath; the 9-minute reproducer recipe; and the two NEGATIVE reproducers
(582M dlsym / 5.6M dlopen clean, 640 forks clean) which still rule out a dl-bookkeeping race.

DOES NOT SURVIVE: the reclaim mechanism, the `mlocked()`/populate-vs-pin framing, and the
"ARC pressure is the trigger" inference. The ARC-pressure correlation may itself be
coincidental, which also weakens the discriminator table I built on it - the third row
("+ ARC pressure -> FAULTS") establishes that the fault needs *something* the first two tests
lack, but not that the something is reclaim.

## The reframed question, now open

**Why does no VMA cover `_dynamic_table` in the faulting address space?** Leading suspect:
`core/mmu.cc:2459-2466` resolves the AS from `sched::thread::current()->address_space()`, and
this tree is `conf_fork=1` with PostgreSQL forking per backend. A thread running with an
unexpected AS, or a child AS missing the dlopened object's VMA, produces exactly "no VMA
covers this address" for a mapping that is perfectly valid in the *other* AS. That is an
AS-bookkeeping/lifetime bug, an entirely different fix layer from reclaim.

This also makes the x86 and aarch64 faults plausible siblings again (the aarch64 one was
characterised as "mapped but not present", and "outside application" may be literal there
too), after I had split them apart. Not assumed - to be tested.

## Lesson
**Check whether the lines you are citing can execute in the configuration under test.** I
quoted `core/pagecache.cc` line numbers for a code path that `conf_zfs=openzfs` disables by
design, and built a fix design plus an upstream PR plan on top of it.

---
# ORIGINAL (WRONG) ANALYSIS BELOW, RETAINED FOR THE RECORD

# CONFIRMED: ARC/pagecache reclaim unmaps loaded-ELF pages under dlsym

2026-09-07. Root-caused, reproduced deterministically, mechanism closed. A generic OSv
kernel bug, found by a benchmark campaign that never got to report a throughput number.

## The causal chain, closed

Discriminator table (the argument that makes this causal rather than correlated):

    dlrace  (dlsym vs dlopen/dlclose, NO I/O)        582,429,800 dlsym / 5,595,884 dlopen -> CLEAN
    dlrace2 (640 forks, cross-AS dlsym, NO I/O)      20,000 dlsym                         -> CLEAN
    dl activity + heavy ZFS ARC eviction             FAULTS

The ONLY added variable was ZFS write/read traffic forcing ARC eviction. dl concurrency
alone never faults; add reclaim and it faults.

Byte-identical fault across two INDEPENDENT triggers on a FRESH boot:

    crash 1 (TPROC-C VU8)      addr 0x0000100000f46000  RIP elf::object::dynamic_tag+12
    crash 2 (ARC pressure)     addr 0x0000100000f46000  RIP elf::object::dynamic_tag+12
    both: page_fault+139 -> lookup_symbol_deep+29 -> dlsym+268
    same RAX/RBX/R10/R11/R14/R15; only per-call args differ

Clinching arithmetic (mine):

    fault 0x0000100000f46000 = program_base + 0xf46000, low bits 0x000 -> EXACT page boundary
    RAX   0x0000100000f46da0 = fault_page + 0xda0      -> walk cursor INSIDE the faulted page

So `_dynamic_tag()`'s `for (auto p = _dynamic_table; p->d_tag != DT_NULL; ++p)` was walking
inside a page that got **unmapped underneath it**. A wild pointer does not land on an exact
page boundary with the cursor mid-page, and would not be byte-identical across two
triggers on a fresh boot.

## Mechanism

- ELF segments are mapped with `mmu::map_file` (`core/elf.cc:445`), so shared-object pages
  are **file-backed and pagecache/ARC-resident**, not anonymous.
- `core/pagecache.cc:395-401` `remove_read_mapping` calls `cp->unmap(ptep)`
  **unconditionally**; `unmap_arc_buf` (:339) / `remove_arc_read_mapping` (:403) drive it,
  then `mmu::flush_tlb_all()` (:350).
- Nothing in that path checks whether the page belongs to a loaded ELF object.

## The fix surface: populate and pin are conflated

OSv ALREADY has the needed concept, which makes the fix narrow and gives it precedent:
- `core/elf.cc:474-477`: `object::mlocked()` is true when the ELF carries a
  **`.note.osv-mlock`** section.
- `core/elf.cc:444`: `flag = mmu::mmap_fixed | (mlocked() ? mmu::mmap_populate : populate)`
- `core/elf.cc:455-466`: a comment documenting that **libsolaris.so is mlocked and never
  unloaded** precisely because reclaim/divergence there "corrupts (e.g. NULL-deref in
  buf_hash_remove)". **This exact class of bug was already hit once and worked around
  per-library.**

But `mlocked()` today only forces *populate at load*. Nothing prevents reclaim from later
unmapping the page. **The defect is that populate and pin are conflated.**

Fix candidates, to design against patches 0030-0032 as a set rather than at the fault site:
1. honour a pinned flag in the pagecache unmap path (most likely correct, smallest);
2. pin ELF-owned file mappings generally;
3. make the dynamic-table walk resilient to a disappearing mapping.

## Reproducer (the real deliverable)

~9m03s to fault after "ready to accept connections", 16 GB shared_buffers / 64 GB guest,
19 GB dataset, all driven from a separate host:
- 8 loops of `psql -c 'do $$ begin perform 1; end $$'` (fresh backend each time, forcing
  dlopen+dlsym of plpgsql.so)
- 4 loops of 200k-row insert / checkpoint / delete / checkpoint
- 2 loops of full-table counts over the dataset
Fault arrived while a "checkpoint starting: time" was in flight, matching the original
crash's "checkpoint starting: wal" correlation.

## The aftermath matters for methodology

Guest does NOT die: qemu keeps burning CPU, postmaster keeps logging, but the network goes
permanently deaf (ARP INCOMPLETE, unreachable even from the host) and fork wedges -
"autovacuum worker took too long to start" every ~15 s indefinitely (24x observed on the
second run, 39x on the first). Connect probe: 138/139 fresh connects failed.

**A naive harness records "connection refused" and blames the network.** This failure mode
silently corrupts benchmark results, which is why the independent connect probe and full
console capture are mandatory instruments.

## Framing: this is a GENERIC OSv bug, not a PostgreSQL one

Any application that dlopens a shared library and then runs under file-backed memory
pressure can hit it. PostgreSQL merely makes it easy: every backend dlopens plpgsql and
every checkpoint creates ARC pressure. That is exactly the **G2 generic-upstreamable-fix**
outcome this program exists to produce - and it came from a benchmark that never reported a
NOPM number. The application was the forcing function, as intended.

## Status
Fix NOT attempted and no PR opened, deliberately: a pagecache/reclaim change interacts with
ARC shrinker patches 0030/0031/0032 on this base and must be designed against all of them
at once. I own the fix design. Both negative reproducers (dlrace, dlrace2) are preserved as
reusable assets - they are what makes the discriminator argument work.
