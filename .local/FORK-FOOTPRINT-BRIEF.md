# Fork per-backend footprint study: the ~0.7GB/backend practical ceiling (and the VU32 median gap)

## THE PROBLEM (operator: "~74 backends isn't going to work in practice")
OSv PG-on-ZFS OOMs at ~74 backends on a 64GB guest: measured ~0.6-0.8 GB PRIVATE per forked backend.
Linux PG backends cost ~5-15 MB private each (shared_buffers/text/libs stay shared), so similar Linux
hosts run HUNDREDS-to-THOUSANDS of backends on the same RAM. OSv is 50-100x heavier per backend. That is
a deployment blocker, not an academic residual: 64GB/0.7GB = ~74 connections max.
SETTLED already (do not redo): it is NOT shared_buffers COW-duplication (sb=16G OOMs, sb=1G completes
VU64; the footprint is present at BOTH sb sizes -> shared_buffers IS correctly shared across fork via the
shared_anon_registry). It is NOT ARC (<=2GB, 8G-cap A/B still OOMs), NOT dirty-data (3.2GB cap OK), NOT a
lost wakeup (6 wake A/Bs refuted; the OOM console proved memory). It IS genuine per-backend private memory.

## THE QUESTION THIS STUDY MUST ANSWER (measure the BREAKDOWN, do not assume)
WHY does an OSv forked backend materialize ~700MB of private pages when the equivalent Linux PG backend's
private heap is ~5-15MB? Per backend, attribute the private footprint to:
  (a) FORK-ARENA COW FAULTS - the per-AS COW-private heap arena (core/fork_arena.cc). A backend's whole
      private heap (relcache/catcache/MemoryContexts/work_mem/sort) lives here. NOTE (verified in source):
      clone_pt_level0 marks private-writable arena pages COW in BOTH parent and child - NOT copied - so a
      child materializes only pages it WRITES. So the cost = pages actually COW-faulted. MEASURE how many.
      *** SUSPECTED AMPLIFIER: the arena is EAGERLY POPULATED (512MB mmap_populate at init, load-bearing so
      alloc never faults IRQs-off). Every arena page EXISTS in the parent, so a child's COW faults
      materialize REAL pages even for logically-free arena space; and any allocator sweep/metadata touch
      across the arena could COW far more than the live data. Also: arena allocation granularity /
      intra-backend free-list reuse - if a backend's arena heap never reuses freed space, it balloons. ***
  (b) PAGE-TABLE CLONE - clone_address_space allocates a fresh PT page at EVERY level per child
      (clone_pt_level<2>/<1> both alloc_page() + recurse). For 16GB shared_buffers that is ~32MB of leaf
      PTs per backend, scaling LINEARLY with mapped size. Real but likely secondary. ALSO: clone_pt_level<1>
      calls split_large_page() on a WRITABLE 2MB large page - splitting the PARENT's mapping PERMANENTLY
      (per fork), destroying hugepages for the parent and ALL future children and multiplying PT cost.
      Check whether MAP_SHARED 2MB pages could stay shared verbatim instead (commit 3364d5c68 claims to
      share writable MAP_SHARED large pages - does this path contradict/gap it? possible regression).
  (c) per-thread STACKS + TLS + syscall stacks per backend.
  (d) genuine PG per-backend private (relcache/catcache) - the Linux-equivalent ~5-15MB baseline.
The dominant term is the fix target. Instrument per-backend: COW-fault count/bytes attributed by VA range
(arena vs other), PT pages allocated per clone, stack/TLS bytes, and the residual.

## ALSO IN SCOPE (#2 - the VU32 median gap, likely the SAME root)
OSv VU32 median is ~0.62-0.72x Linux and the idle->wake tail fix (#1511) did NOT lift it. Hypothesis: the
same per-backend footprint causes MEMORY PRESSURE at VU32 (reclaim churn, ARC squeezed to 2GB when it
should use its 32GB cap, COW-fault storms) that costs throughput WITHOUT OOMing. TEST: at VU32, measure
free-mem/ARC-size/COW-fault-rate/reclaim activity; then re-run VU32 with the footprint REDUCED (smaller
shared_buffers, or the (a)/(b) fix once you have it) - does the VU32 median RISE toward Linux? If yes, the
footprint is the dominant residual at BOTH VU32 and VU64 and one fix addresses both. If the VU32 median is
unmoved by footprint reduction, it is a DISTINCT throughput factor - name it separately (that is a valid
result and it splits the two residuals cleanly).

## FIX DIRECTIONS (whichever the breakdown names; each is a generic G2 memory-management improvement)
- Arena: do not eagerly populate the whole 512MB where a child inherits it (or make the child's arena
  lazily-committed / much smaller / per-backend right-sized), fix intra-backend free-list reuse, reduce COW
  amplification (avoid allocator sweeps touching the whole arena). Preserve the alloc-never-faults-IRQs-off
  invariant (that is why eager populate exists - any change MUST keep alloc fault-free or move the fault
  to a preemptible context).
- Page tables: share PT subtrees for genuinely shared regions instead of cloning every level; keep writable
  MAP_SHARED 2MB pages shared verbatim (no split_large_page) so hugepages survive fork.
- Stacks/TLS: right-size per-backend.
TARGET: get per-backend private from ~700MB toward Linux's ~10MB order, i.e. support HUNDREDS of backends
on a 64GB guest. Even a 5-10x reduction (700MB -> 70-140MB) takes ~74 backends to ~450-900 - practical.

## VALIDATION
- The breakdown table (per-backend private attributed to a/b/c/d) BEFORE and AFTER the fix.
- Max backends before OOM on a fixed-RAM guest: before vs after (the practical number that matters).
- VU64 runs to completion at realistic shared_buffers (not just sb=1G), and push VU128/VU192.
- The VU32 median: does it rise with the footprint reduced (answers #2)?
- No regression: correctness (fork/COW semantics, the shared_anon_registry, MAP_SHARED coherence - the 8
  cross-AS scopings must still hold), the alloc-never-faults invariant, p99, and the leak fixes (#1/#2).

## SUBSTRATE: hotdog (585335547908, us-east-2, --region explicit), quota 1152, keypair osv-hotdog, SG
## sg-0a0fec26afe57cd43 (ALREADY /32-scoped - NEVER 0.0.0.0/0, never widen), subnet us-east-2a
## subnet-04a66ccb68b2a2f13, Debian 12 ami-0dc1629a58a7d6458. Base bank/fork-arena-real-reclaim (all fixes,
## gate-PASS) + apps 3f93f43. Raw NVMe passthrough. NEVER SIGKILL qemu mid-CHECKPOINT. hotdog is SHARED
## with solnix (Owner=gregburd) - only touch Owner=agent-* we create. Reuse .local/cwwake + .local/gates
## scaffolding (MEMPROBE per-pool sampler already exists in cwwake - extend it for the per-backend breakdown).

## FAILED ATTEMPT 1 (agent 66b08ee9, 2026-09-19): ended its turn after ~3min/18 tool uses right after
## reporting box IDs ("Starting host bootstrap while I study the source") leaving an m5d.metal + a
## c5.4xlarge RUNNING and orphaned (~22min idle burn before I caught it). A resume attempt also died.
## I TERMINATED both (i-0386137bc2f8d0dbb, i-0b6ee4b1cad272444), 0 orphan volumes. Scaffolding it wrote
## IS saved in .local/footprint/ (launch.sh, env.sh, host-setup.sh, build-image.sh, boot-osv.sh, instr.sh,
## hdb.sh, drv-setup.sh, quiesce.sh) - a relaunch can reuse it.
## LESSON (standing, for every EC2 agent brief): an agent MUST NOT end its turn while a box is live. The
## brief must say: work CONTINUOUSLY (launch long steps with nohup + poll in a loop); if you must stop for
## ANY reason, TERMINATE THE BOXES FIRST then report; never end a turn with a metal box running. Also:
## prefer launching the box only AFTER the local build/setup work is done, so an early death cannot orphan
## metal. And the main agent should CHECK for orphans promptly after any agent goes quiet.

## ROOT CAUSE FOUND IN LOCAL SOURCE ANALYSIS (agent c1991ff6, 2026-09-19, before any EC2 spend):
IT IS A FIXABLE BUG, NOT AN INHERENT COST - and it is a tradeoff OUR OWN leak-#2 fix introduced.
MECHANISM (verified in gh-fork/bank/fork-arena-real-reclaim:core/fork_arena.cc):
 - free() returns UNCONDITIONALLY for any pointer in the slot-97 per-AS overflow region (`if
   (in_overflow(p)) return;`) - BY DESIGN for C2-safety (a cross-AS free must not read a chunk header at
   a VA mapped only in the dead/other child; the region is reclaimed WHOLESALE on reap).
 - g_bump is a GLOBAL 512MB bump shared across ALL address spaces -> at 74 backends that is ~7MB each and
   exhausts almost immediately -> thereafter EVERY allocation goes to overflow_alloc() = fresh per-AS 1MiB
   mmap_populate (eager, real RAM) regions with ZERO intra-lifetime recycling.
 => A backend's committed RAM tracks its LIFETIME MALLOC CHURN, not its live heap. PG backends churn
    MemoryContexts per query with a SMALL live heap = the pathological case. That is why OSv is 50-100x
    glibc (which recycles), and it explains the earlier trajectory's "RSS kept climbing AFTER backend count
    maxed at 74" (churn accumulating, not new forks).
ALSO a PROBE HOLE caught: the prior FP probe's ovf_pages.fetch_add is NEVER CALLED, and overflow pages are
committed by mmap_populate (not COW-faulted) - so the prior probe would have MISSED the dominant term and
mis-attributed the footprint. Probe corrected to count overflow COMMITTED BYTES separately from COW faults.
DISCRIMINATOR (steered, proves churn-proportional vs fixed-per-fork): an idle post-fork backend should cost
LITTLE vs a 60s-querying backend costing hundreds of MB; footprint ~linear in per-backend query count/
duration; shorter run at the same backend count OOMs later or not at all.
FIX SHAPE (must PRESERVE C2-safety - the constraint that created the bug): add INTRA-AS recycling for
overflow chunks with NO cross-AS header read. (a) a per-AS free-list only the OWNING AS pushes/pops (head
in the BSS slot so no foreign AS reads an arena page; a foreign-AS free stays a no-op as today), or (b)
make the arena PER-AS-sized instead of one global 512MB bump (so each AS recycles its own and overflow is
rare), or (c) size-class free-lists inside the overflow region touched same-AS only. Invariant: FOREIGN-AS
free remains a no-op; the OWNING AS recycles. That collapses churn-proportional -> live-heap-proportional.
TARGET: ~0.7GB/backend -> tens of MB => ~74 backends -> hundreds. Headline validation = MAX BACKENDS
BEFORE OOM before/after, + VU64 at realistic shared_buffers, + does the VU32 median rise (one fix, both
residuals?).

## THE CHURN FIX (agent c1991ff6, pushed gh-fork/bank/fork-footprint-reduction @ 1f277a56d, compiles clean)
DESIGN (elegant - solves the exact constraint that created the bug): carve slot 97 into DISJOINT PER-AS VA
WINDOWS (2 GiB per AS slot, 256 windows tiling the slot, static_assert'd). That restores VA->owner
arithmetic FROM BSS ALONE: (va - ovf_slot_base) / ovf_window_sz IS the owning slot index. So free() decides
same-AS vs foreign WITHOUT READING THE ARENA PAGE - C2-safety preserved EXACTLY (a foreign-AS free remains
an unconditional no-op, as today) while the OWNING AS recycles through its normal per-class free-list.
Churn-proportional -> live-heap-proportional. Env-gated OSV_FORK_OVF_RECYCLE (1=default/fix, 0=old no-op
behavior) so the A/B is one build + two boots.
ALSO FIXED (two more latent bugs in the failed attempt's tooling, caught by actually compiling/running it):
 - the prior probe dumper would NOT COMPILE: `new sched::thread(...)` (private ctor; needs
   sched::thread::make) - so footprint1's probe had never been through a compiler.
 - the prior applier script was NON-IDEMPOTENT: its guard grepped `fork_arena_bump_used` but the real
   symbol is `bump_used`, so a second run double-applied and broke the build. Applier DROPPED entirely;
   probe+fix are committed on the branch and build-image.sh only VERIFIES markers now.
 - probe overflow hole closed: now reports ovfcommit_MB / ovfrecycled_MB / ovflive_MB / ovfforeign.
VERIFIED LOCALLY BEFORE LAUNCH: fix compiles (core/fork_arena.o + core/mmu.o), bench-base-gate PASS (9/9),
and a local invariant self-check (test_ovf_owner.py) proved the per-AS window arithmetic is exact, windows
tile slot 97 with no gap/overlap, owner recycles / foreign no-ops.
DRIVERS: churn-discriminator.sh (idle vs light vs heavy at FIXED backend count - isolates churn from fork
count) + max-backends.sh (the headline sweep). Boxes: METAL i-08caff61e534e9900, DRV i-0affb9a64f77d60c4.
