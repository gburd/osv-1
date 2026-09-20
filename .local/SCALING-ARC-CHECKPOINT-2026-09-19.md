# Scaling arc checkpoint (2026-09-19) - the whole M1/wakeup investigation, honestly

## THE ARC (each layer named by measurement; several hypotheses refuted en route):
"PG slower on HammerDB" -> run-order/harness ARTIFACT (the decline was multi-cell-per-boot + voiding the
healthy r1) -> the REAL bug behind it = TWO fork/teardown LEAKS (fd/gfdt EMFILE + fork-arena memory) ->
idle->wake TAIL low-mode (VU32) -> and the VU64 wall = a fork per-backend memory-footprint OOM COST.

## MEASURED M1 SCALING (matched OSv-vs-Linux, m5d.metal, io_uring both, fresh-boot-per-cell):
  VU8/16 : OSv FASTER than Linux (1.17x / 1.29x).
  VU32   : idle->wake tail FIXED (#1511); median ~0.65x Linux (open: footprint pressure or a throughput
           factor - NOT a wake bug, NOT a lost wakeup).
  VU64   : OOM at ~74 backends on the ~0.7GB/backend OSv-fork footprint (COST, not a bug; Linux footprint
           smaller). Mitigation: more RAM or smaller shared_buffers (sb=1G completes VU64).

## UPSTREAM (direct-to-master, NOT fork-blocked) - the scaling arc's shippable wins:
- #1511 sched: adaptive per-CPU idle-spin window (idle-safe + idle->wake tail; supersedes #1501). OPEN.
- #1472 sched: idle-CPU pull work-stealing (wake-pull, default-on). OPEN.
- #1480 sched: take the lock before checking the wait queue in condvar. OPEN.
- #1484 sched: skip waking a null/invalid thread pointer. OPEN.
- #1464 sched: disperse threads faster in the load balancer. APPROVED (awaiting merge).
  (These are the standalone scheduler fixes the cross-vCPU-wakeup investigation produced.)

## BANKED, VALIDATED, blocked ONLY on the fork-composition keystone (#1455/#1456 decision + the #1458
## S1..S8 proposal, no maintainer reply yet):
- bank/fork-fd-reap-leak(-reviewready): leak #1, 400-round A/B validated. Lands as S5.
- bank/fork-arena-real-reclaim: leak #2, 5-gate validated + 8 cross-AS coherence scopings. Lands as S8.
- bank/fork-arena-grow-mitigation: RETIRED (superseded by real-reclaim).
- bank/sched-adaptive-idle-spin: the fork-stacked precursor to #1511 (which is the clean master version).

## THE VU64 RESIDUAL (the current open frontier) = OSv fork per-backend memory footprint (~0.7GB/backend).
## NOT a scheduler/wake bug (6 A/Bs + OOM console refuted that). Options: (a) mitigation (RAM/shared_buffers
## sizing, documented), (b) a G2 fork-footprint-reduction study (reduce the COW page-table clone + per-AS
## private anon per backend - the same fork machinery the leak fixes touched), (c) revisit the VU32 median
## gap (is it the same footprint pressure, or a distinct throughput factor?).

## ACCOUNT: hotdog (585335547908), quota 1152, all agent boxes terminated, 0 orphans, 0 volumes, SG /32
## (NEVER 0.0.0.0/0), shared with solnix (only touch Owner=agent-* we create).

## OPEN OPERATOR DECISIONS (next direction):
1. fork-footprint-reduction study (the VU64 residual, a real G2 memory improvement, needs EC2), OR
2. revisit the VU32 median gap (footprint vs throughput - could reframe VU32 too), OR
3. shift to M2/PGXN (the next milestone - every PGXN extension identical OSv-vs-Linux; exercises the
   dlopen/ELF path the fork fixes repaired). The M1 scaling story is now honestly characterized end-to-end.
## Plus standing: the maintainer is offline (since 2026-08-03) - the merge queue + the fork-composition
## keystone (#1458 proposal) await them; nothing I can force.

## DISPATCHED (2026-09-19, operator: "~74 backends isn't going to work in practice"): agent 66b08ee9
## (Owner=agent-footprint) doing BOTH #1 and #2 in one study, since they likely share a root:
## #1 the fork PER-BACKEND FOOTPRINT (~0.7GB/bk vs Linux ~5-15MB = 50-100x; caps PG at ~74 backends on
##    64GB where Linux runs hundreds-thousands). MEASURE the breakdown per backend: (a) fork-arena COW
##    faults [suspected amplifier: the 512MB arena is EAGERLY populated so every page exists in the parent
##    -> COW faults materialize real pages even for logically-free space; + allocation granularity /
##    intra-backend reuse], (b) page-table clone [clone_pt_level<2>/<1> alloc_page per level per child,
##    ~32MB leaf PTs/backend for 16GB sb, linear in mapped size; + split_large_page on WRITABLE 2MB pages
##    mutates the PARENT permanently killing hugepages for parent+all future children - possible gap vs
##    commit 3364d5c68], (c) stacks/TLS, (d) genuine PG private (~5-15MB Linux-equivalent baseline).
##    Then REDUCE the dominant term (preserving the alloc-never-faults-IRQs-off invariant that eager
##    populate exists for, + fork/COW semantics + the shared_anon_registry + the 8 cross-AS scopings +
##    the leak fixes). TARGET: 700MB -> tens of MB, i.e. ~74 backends -> hundreds. Validate by MAX BACKENDS
##    BEFORE OOM (the practical number) + VU64 at realistic shared_buffers + VU128/192.
## #2 the VU32 MEDIAN gap (~0.65x Linux, NOT fixed by #1511): hypothesis = the SAME footprint causes memory
##    pressure (reclaim churn, ARC squeezed to 2GB vs its 32GB cap, COW-fault storms) costing throughput
##    without OOMing. TEST: does the VU32 median RISE when the footprint is reduced? YES -> one fix addresses
##    both residuals. NO -> the VU32 gap is a DISTINCT throughput factor, named separately (clean split).
## MY CORRECTED ARITHMETIC (banked so it is not repeated): I first theorized a flat 512MB arena copy per
## backend (512x74=37GB ~= the 42GB measured - a tempting match) but VERIFIED IN SOURCE that
## clone_pt_level0 marks private-writable arena pages COW in BOTH parent and child - NOT copied. So the
## cost is pages ACTUALLY COW-FAULTED, not a flat copy. The real question is therefore WHY a backend
## materializes ~700MB when Linux's equivalent private heap is ~10MB (a 50-100x amplification) - which is
## what the breakdown measures. Assumption corrected before dispatch, not after.
