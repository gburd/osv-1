# THE PG-ON-OSv DECLINE: ROOT-CAUSED (2026-09-16). It was TWO per-backend-reap leaks, not a scaling wall.

## Context: the "decline" was a run-order artifact (see .local/M1-REFRAME-LANDMARK.md) - fresh-boot is
## healthy (VU32=215k). The REAL bug is a within-boot progressive wedge across forked-backend churn.
## Root-caused to TWO independent leaks on backend reap (agent b19ea12a, m5d.metal, churn-loop repro):

## LEAK #1 - fd/gfdt leak: ROOT-CAUSED + FIXED + A/B-VALIDATED
MECHANISM: OSv has ONE shared global fd table gfdt[FDMAX=65536]. release_inherited_fds() on backend
reap did `g_child_opened_fds.erase(child_as)` - forgot but NEVER CLOSED the fds a backend opened itself
after fork. Real Linux closes the whole fd table on process exit; OSv's shared-table reaper dropped only
INHERITED refs -> every child-opened fd leaks -> gfdt fills to FDMAX -> pipe()/accept() EMFILE -> hard wedge.
REPRO: 32-conn churn loop + autovacuum. gfdt-occupancy grows ~290 fds/round (linear), everything else flat
(threads ~658, ASes ~5, reaper queue ~0, all fork maps ~5). EMFILE first at ROUND 223.
FIX (gh-fork bench/leakhunt ac6a389d2, env OSV_FORK_FD_REAP default ON): on reap, snapshot the child's
still-open child-opened fds under g_fd_lock, then (lock released) close each via new helper
fork_reap_close_child_opened_fd(fd) - null gfdt[fd] iff it still points at that file, then fdrop. These
fds are SOLELY owned by the exited backend (fresh post-fork slot) so closing is unconditional/safe.
A/B (250 rounds, MEASURED):
  gfdt peak: FIX OFF = 65536 (FDMAX, climbs 32->65536 linear); FIX ON = ~30-55 (FLAT)
  first failure: FIX OFF = round 223 EMFILE; FIX ON = NONE, all 250 rounds ok=32 fail=0
Leak #1 ELIMINATED. Evidence: .local/leakhunt/AB-off.log, AB-on.log.

## LEAK #2 - per-fork memory leak: NAMED, characterized, FIX DEFERRED (the next root cause)
With the fd fix ON the guest still OOM-wedges ~round 280: mem_free monotonic 23GB->29MB ("could not
reclaim any further" - NOT ARC). PER-FORK not per-query (bare SELECT 1 connect churn leaks it too),
~0.74 MB/backend. HYPOTHESIS (source-backed): identity-heap-fallback allocations after the 512MiB
fork-arena exhausts, not tied to the address_space so not freed on destroy_address_space(). Needs the
same treatment: name the exact allocation site, tie it to the AS, free it on reap. SECOND dedicated hunt.

## PR TARGET: master has gfdt[] but NOT g_child_opened_fds (the inherited/child-opened tracking is a
## NEWER fork-fd-table generation on the bench branches, commit f411d5edc line, NOT in open #1455/#1456).
## => the fd fix stacks onto whatever PR carries this fork-fd-table generation; NOT standalone vs master.
## Ideal: the leak never reaches master - fixed pre-merge. G-signed, honest scope, the measured A/B curves.

## SIGNIFICANCE: this IS the production wedge. A DB churns connections + autovacuum workers for weeks;
## leak #1 wedges it (EMFILE) in ~223 backend-churn rounds, leak #2 OOMs it ~280. Both invisible to a
## reboot-per-cell benchmark. Generic OSv fork/teardown correctness - G2 platform fixes, PG the forcing
## function. Leak #1 done; leak #2 is the immediate next hunt to fully close the decline.

## UPDATE (2026-09-16, reconciled): leak #1 fix confirmed across 400 rounds (gfdt flat ~29-46 vs
## fix-OFF 65535/EMFILE@224). Leak #2 rate reported ~0.74MB (final) and ~1.8MB (400-round run) - same
## leak, different denominator; the leak2 agent (9bec3830) measures it fresh. CONFIRMED: leak #2 is
## INDEPENDENT + PRE-EXISTING (present fix-OFF too; fds just wedged FIRST @224 before OOM @280) - NOT
## caused by the fd fix. Two genuinely separate fork/teardown bugs. Agent 9bec3830 hunting leak #2 on a
## FRESH box; b19ea12a done + box terminated (0 orphans, no overlap). The out-of-order <subagent-update>
## was b19ea12a's in-flight message just before it wrapped; it did NOT continue - leak #2 is 9bec3830.

## BANKED FOR UPSTREAM (2026-09-16):
- LEAK #1 FIX: clean, probe-stripped, G-signed commit ff7f8c0f5 pushed to gh-fork bank/fork-fd-reap-leak
  (2 files: libc/process/fork.cc + fs/vfs/kern_descrip.cc; the OSV_LEAK_PROBE debug instrumentation was
  stripped - it must NOT merge). Documented in PR #1458 (fork+ZFS tracking / DO-NOT-MERGE) with the
  mechanism + the measured 400-round A/B (gfdt flat ~29-46 vs climbs-to-65535-EMFILE@224).

## LEAK #1 PR-SHAPE DETERMINED (2026-09-17, agent leak1pr) - full writeup .local/leak1-pr/RESULT.md:
  Determined the minimal correct base + made it BUILD. The fix depends on the 3-commit shared-gfdt
  fd-table generation (8c8f53d2d / a377258ce / f411d5edc = 46333ccea twin), which has a HARD BUILD DEP on
  the fork arena (fork_arena::kernel_heap_scope, include/osv/fork_arena.hh - 9 instantiation sites in
  fork.cc incl. the reaper closure). VERIFIED: #1455 (dce0d32fd) and #1456 (e9a31b1ab) carry NEITHER the
  gfdt symbols NOR core/fork_arena.cc / fork_arena.hh; cherry-picking gfdt-gen onto #1456 CONFLICTS on the
  first commit (missing fork_arena.hh) and would not build. The coherent base is gh-fork wip/fork-clone-scan
  (65279b938: fork base + COW AS + fork arena + gfdt-gen), which is 134 commits ahead of upstream/master
  with NO open PR. => Option 2a (openable PR) is NOT viable; base does not exist upstream. Delivered
  option 2b: review-ready branch gh-fork bank/fork-fd-reap-leak-reviewready (fork-clone-scan base + an apps
  base-fixup repinning apps 57c60798->5cb19033 since 57c60798 is a dangling gitlink unreachable on the apps
  remote + the pure 2-file G-signed reap fix). BUILD-VALIDATED: both changed TUs compile under CONF_fork=1
  (fork.o + kern_descrip.o produced; nm shows T fork_reap_close_child_opened_fd in kern_descrip.o, U in
  fork.o, reap_enabled gate static present). Source byte-identical to ff7f8c0f5 (the 400-round-A/B source),
  so no metal re-run. #1458 leak-#1 section refreshed to point at the review-ready branch + state the
  blocker. No EC2 used. Original single-commit bank/fork-fd-reap-leak preserved unchanged.
- WHY NOT A STANDALONE PR: the fix depends on the shared-gfdt fd-table generation (46333ccea:
  g_inherited_fds/g_child_opened_fds/fork_child_owns_fd), which is CONF_fork-guarded, depends on the
  child-AS machinery (#1455/#1456, unmerged), conflicts with the OLDER fd model in open #1455/#1456, and
  is NOT in any open PR (it lives on the bench branches / the 78-commit wip/pg-scale-fix grab-bag). A PR
  from the fix's base = 165 commits ahead of master = unreviewable. So the honest banking is: preserve
  the clean fix commit as a bank branch + record it in the #1458 stack; it lands as one clean commit when
  the fork-fd-table generation is proposed (part of the maintainer's pending #1455/#1456 composition
  decision). NOT pre-empting that decision, NOT manufacturing an unreviewable PR.
- LEAK #2 FIX (when agent 9bec3830 lands it): same path - clean commit on the same bank stack + a #1458
  section. Already noted as "under investigation" in the #1458 body.

## LEAK #2 ROOT CAUSE CONFIRMED (agent 9bec3830, box i-063d9d27134f102b1):
The fork arena (core/fork_arena.cc) uses a GLOBAL MONOTONIC bump pointer g_bump (never-reused VA,
unique per-AS) + PER-AS free-lists (recycled within a process, reclaimed on release_as). release_as()
drops the dead child's per-AS freelist SLOT but explicitly does "No teardown needed for the shared bump
pointer" - the carved VA is NEVER returned to g_bump. So under unbounded fork/reap churn g_bump marches
monotonically to the 512MB arena cap; once exhausted, EVERY forked backend's whole heap falls back to
the identity heap, which destroy_address_space NEVER frees on reap -> 0.770 MB/reaped-backend leak
(measured; gross fallback 0.921MB/backend over ~128 allocs). EVIDENCE: fb_bytes counter added to
std_malloc shows mem_free FLAT through ~350 reaped backends (arena 1->20MB, fb=0), then at the INSTANT
g_bump exhausts (arena 20->512) fb_bytes + mem_free drop begin IN LOCKSTEP. Crisp transition = airtight.

## LEAK #2 FIX (in progress): return a dead child's carved VA to a global reclaim pool on release_as so
the arena keeps serving + the identity-heap fallback never triggers. CORRECTNESS CRUX (steered): the
arena keeps free-lists PER-AS ON PURPOSE (no cross-COW-boundary recycle); returning VA to a GLOBAL pool
for re-carve by a later child crosses that boundary - MUST prove the dead AS's VA is FULLY UNMAPPED at
release_as (no stale PTE/aliasing) before re-issue, and VALIDATE data integrity (each backend writes a
known pattern, a later backend verifies no bleed-through) not just that mem_free goes flat. If VA-reclaim
proves racy, the SAFE fallback fix = make the identity-heap fallback allocation AS-tied so
destroy_address_space frees it on reap (arena still exhausts but leak-free, no cross-AS hazard). A safe
bounded fix beats an elegant racy one. Env-gated (OSV_FORK_ARENA_RECLAIM). Banks same path as leak #1
(clean commit, probe stripped, G-signed, #1458 section) once the 3-way validation (mem flat + arena
bounded + ZERO corruption) passes.

## LEAK #2 FIX - iteration log (agent 9bec3830, good engineering judgment throughout):
- Attempt 1 VA-reclaim: ABANDONED - crashed with mmap fault in PG fork path (reissued VA faults; the
  arena base mapping never munmapped, child COW-clones parent's slot PTs not AS0's). Failed SAFELY under
  test, exactly as the correctness-crux steer warned. Confirms cross-AS VA reuse is unsafe.
- Attempt 2/3 AS-tied fallback tracker: CORRECTNESS PROVEN (8KB unique payload/backend, md5 + prefix-
  bleed check, totalCORRUPT=0 all rounds both arms - no cross-AS corruption). But SLOW: single g_fb_lock
  per-object under 32-way exhausted-arena churn wedges ~round 60 (leak stopped, guest too slow to serve).
  The wedge correctly diagnosed: per-object bookkeeping under a global lock is too hot.
- Attempt 4 (building): PER-AS COW-PRIVATE OVERFLOW BUMP REGION - each child AS bumps in its OWN private
  region (own mmap/VA, NOT the global g_bump space), freed wholesale by destroy_address_space page-table
  teardown (the SAME mechanism release_as already uses for per-AS freelist chunks). Zero per-object
  bookkeeping, zero teardown cost, zero lock contention, no cross-AS VA reuse. Generalizes the arena's
  own model rather than bolting on a tracker = lazy-correct. Reframe: the identity-heap fallback WAS the
  bug (global, unfreed); the correct fallback is a per-AS overflow bump (freed on reap).
- INVARIANT (steered): the overflow region must be PER-AS (not global g_bump) or it just moves the
  exhaustion. VALIDATION GATE = all three: mem_free FLAT + NO wedge (throughput holds to round 300+) +
  totalCORRUPT=0. Sharded-lock tracker = documented safe fallback if approach 4 snags. Env-gated. Banks
  same path as leak #1 (clean commit, probe stripped, G-signed, #1458 section) on passing the 3-way gate.

## GENERAL LESSON (bank to memory when MCP up): a leak fix that stops the leak but WEDGES the guest is
## NOT a fix - a bounded-but-slow guest that cannot serve fails the production requirement. The agent
## refusing to ship v2/v3 wedging fixes = correct. And: reuse the mechanism already in the code
## (wholesale page-table teardown) over bolting on new bookkeeping - the arena already frees per-AS state
## on release_as; the fix extends that, it does not invent a parallel tracker.

## LOAD-BEARING INVARIANT proven by leak-#2 fix (agent 9bec3830, by elimination - 2 crashes same fault):
ANY per-AS-private VA that free() must touch BY RANGE is UNSAFE, because free() CROSSES address spaces:
the reaper (AS0), a sibling, or a later child frees a chunk whose VA is mapped ONLY in the (dead or
different) child that allocated it -> recover()/free reads the chunk header at a VA unmapped in the
freeing context -> page_fault -> Abort. (Crashed both the VA-reclaim design AND the per-AS-overflow-region
design at ~round 10, same fault signature.) THEREFORE: the ONLY safe home for memory that must be freed
across AS is a VA COHERENT IN EVERY AS = the OSv identity heap. The fork arena's global-monotonic-bump +
never-touch-a-freed-VA-from-another-AS is load-bearing, not incidental. The AS-tied identity-heap tracker
is thus the ONLY correct design for reclaiming the post-exhaustion fallback allocations - not a fallback,
the answer. Remaining work is PURELY throughput (the alloc/free hot path must not take a GLOBAL lock - the
v3 wedge; use per-AS chains (option A) or striped locks (option B), tracking metadata itself on the
identity heap so the reaper can walk it cross-AS).

## STATUS: agent 9bec3830 at ~28% context / 219 tool uses, building the fast identity-heap tracker
## (per-AS chain, no global hot-path lock). 3-way gate: mem flat + no wedge to round 300 + totalCORRUPT=0.
## If it runs low on context before landing, hand off with: the invariant above + the proven-correct
## tracker (0 corruption) + the ONLY-throughput-left framing + the corruption harness (8KB md5 payload).

## LEAK #2 FIX ATTEMPT - fix_striped.py (striped tracker) VALIDATED + FAILED (agent-leak2b, box
## i-0d75e6472ec9328ea, m5d.metal, 2026-09-16). The "ONLY-throughput-left" framing above was WRONG:
## the striped tracker is NOT just slow, it is UNSAFE. THIRD FLAW, unikernel-specific:
## OSv runs the kernel ON the app thread. During a child backend's open() syscall the kernel does
## `new vnode()`/dentry/file with app_thread=true and current_AS=child, so post-exhaustion those
## KERNEL objects fall to the identity heap and the tracker records them under the child AS. On reap
## fork_arena_free_as_fallbacks() free()s them -- but they are RCU/refcount-freed by the kernel's OWN
## path (file::~file -> drele/vrele). DOUBLE FREE -> the RCU quiescent-state thread page-faults on the
## freed vnode -> ABORT ~round 175. Backtrace: handle_mmap_fault<-vm_fault<-page_fault<-vrele<-drele<-
## file::~file<-osv::rcu::cpu_quiescent_state_thread. Both PG app malloc() and kernel operator new go
## through the SAME std_malloc app-thread arena branch; there is NO marker to separate app heap (reap it)
## from kernel vfs objects (kernel frees them). force_kernel_heap is only around explicit global-mem
## sections (zio_t), NOT vfs alloc. => the tracker-reap premise "child-AS fallbacks == the backend's app
## heap" is FALSE; more stripes/FB_AS_PER cannot fix it (changes throughput, not WHICH objects free).
## Gate: (a)mem_free FLAT PASS-until-crash, (b)NO WEDGE FAIL(crash), (c)CORRUPT=0 PASS-until-crash.
## CONTROL (fix OFF, no tracking): 320 rounds clean, mem_free monotonic 23042->5351MB (leak real).
##
## REFRAME (correct, code-confirmed): the arena handles BOTH app+kernel objects correctly PRE-exhaustion
## (both route to arena; free()=freelist push; release_as drops freelist; pages freed by teardown). The
## ENTIRE problem is post-exhaustion IDENTITY-HEAP fallback. => the fix is MAKE THE ARENA NOT EXHAUST,
## not track+reap. MEASURED (carve_measure.py, 300 rounds): a bounded g_bump TOP-REWIND is NON-VIABLE --
## reclaims only 45/511MB=8.8%; reap_top=6 vs reap_buried=271 (97.8% buried); carve pattern is INTERLEAVED
## not LIFO (short backends carve above long-lived ones, die first, leave buried holes). rewound plateaus
## at 45MB early and never grows. => top-rewind dead.
## RECOMMENDED next-build design (NOT built): per-AS COW-private OVERFLOW region whose free() does NOT
## read the chunk header cross-AS -- range-check the pointer against BSS-recorded per-AS region bounds and
## NO-OP the free (the whole region is reclaimed wholesale by destroy_address_space page teardown, same
## mechanism release_as uses). The range check reads only kernel BSS, never the possibly-unmapped chunk
## page -> no cross-AS fault (that was the specific crash of the earlier per-AS-overflow attempt: free()
## read the size/class header at a VA unmapped in AS0). Kernel objects RCU-freed later also hit the no-op
## free -> no double-free, no leak. Stopgap alt: enlarge arena 512MiB->several GiB. Full writeup +
## evidence: .local/leak2/RESULT.md, {ON,OFF,CARVE}-{console,integ}.log, carve_measure.py. Box terminated,
## 0 orphans.

## LEAK #2 CONTINUATION (2026-09-16, after the stopped agent):
The leak-2 hunt agent (9bec3830) was STOPPED at 30% context with its box orphaned. Recovery:
- Terminated the orphaned box i-063d9d27134f102b1 (0 orphans, 0 volumes) - it had no validated fix on it.
- The stopped agent converged (by elimination) on the CORRECT design: AS-tied identity-heap fallback
  tracker, striped 256 ways (per-stripe spinlock, not one global lock which wedged), chained O(1)
  insert/erase/reap, tracking metadata in fixed BSS (cross-AS coherent), excludes >=2MiB. Saved as
  .local/leak2/fix_striped.py (+ fix_striped.SAVED.py). Never validated on-box (agent stopped mid-build).
- Dispatched CONTINUATION agent caf059ef: apply fix_striped.py -> build -> 3-way validation gate
  (mem flat + no wedge to round 300 + totalCORRUPT=0) -> bank on gh-fork bank/fork-arena-fallback-reclaim
  + a #1458 section, IF it passes. Does NOT redesign (two simpler designs proven to crash; this one
  reached by elimination).

## LEAK #2 - THE THIRD FLAW (2026-09-16, agent caf059ef, box i-0d75e6472ec9328ea): tracker-reap is
## FUNDAMENTALLY UNSAFE in a unikernel. The striped AS-tied identity-heap tracker (fix_striped.py)
## applied+built clean, ran ok=32 through arena exhaustion with mem_free FLAT + CORRUPT=0, then ABORTED
## ~round 175: handle_mmap_fault<-vm_fault<-page_fault<-vrele<-drele<-file::~file()<-rcu cpu_quiescent.
## ROOT CAUSE (design, not tuning): OSv runs the KERNEL ON THE APP THREAD during syscalls. The tracker's
## gate (app_thread && current_AS != kernel_AS) therefore CATCHES kernel-owned vfs objects (file/vnode/
## dentry) that the kernel allocates on the identity heap WHILE servicing a child's open()/read(). Those
## have INDEPENDENT RCU-deferred lifetimes; reap-freeing them double-frees vs the RCU path -> UAF -> abort.
## The tracked set is NOT "the backend's app heap" - it includes kernel objects indistinguishable from
## app allocations at the std_malloc boundary. More stripes / bigger FB_AS_PER cannot fix this.
## CONTROL (OSV_FORK_ARENA_RECLAIM=0): ran ALL 320 rounds, no crash, leak reproduced (mem_free
## 23042->5351MB, ~0.77MB/backend) - leak is REAL, tracker-reap is the wrong mechanism.

## THE REFRAME (from reading mempool.cc, guides the corrected design):
The arena ALREADY handles BOTH app + kernel objects correctly PRE-exhaustion (routing: arena iff
ready && !force_kernel_heap && child; arena free() = per-AS freelist push; release_as drops the list;
kernel objects RCU-free normally through arena free). The FLAT pre-exhaustion phase proves it. The
ENTIRE bug is post-exhaustion fallback to the IDENTITY heap (release_as does not cover it). So the fix
is NOT a reap-tracker - it is MAKE THE ARENA NOT EXHAUST (no fallback -> no double-free hazard). The
arena exhausts because each fresh child bump-carves new g_bump VA and never returns it (physical pages
ARE freed on release_as; only VA leaks). CORRECTED-DESIGN CANDIDATES (fresh run builds from the writeup):
 1. BOUNDED g_bump REWIND: return the top-most fully-dead AS's carve to g_bump when no younger carve is
    live (PG backends are LIFO-ish under churn). NO cross-AS VA reuse (never hand A's VA to B; only rewind
    g_bump past a dead top region) -> sidesteps the free()-crosses-AS-by-range wall that crashed
    VA-reclaim + per-AS-overflow. VIABLE IFF the carve pattern is reclaimable-at-top (agent measuring).
 2. If g_bump growth is interleaved (not reclaimable-at-top): size the arena much larger (bounded
    stopgap), OR a per-AS overflow region whose free() stores size OUT-OF-LINE so a cross-AS free from
    AS0 does not read an unmapped chunk header (the specific fault that crashed per-AS-overflow).
## KEY NEW CONSTRAINT (bank to memory): in a unikernel you CANNOT distinguish app-heap from kernel-heap
## allocations at the low-level malloc boundary - the kernel runs on the app thread. Any fork/teardown
## reclaim keyed on "app thread + child AS" will wrongly capture kernel objects with independent lifetimes.

## LEAK #2 - CONVERGED ANALYSIS (2026-09-16, after 4 refuted fix designs + source study):
THE g_bump REWIND EXPERIMENT (decisive, measured): carve pattern is INTERLEAVED not LIFO - a greedy
top-rewind reclaims only 8.8% (reap_top=6 vs reap_buried=271, 97.8% buried). Bounded-rewind is NON-VIABLE.

CRITICAL REFRAME (from source study): the crash at ~round 175 was TRACKER-INDUCED. The control arm
(OSV_FORK_ARENA_RECLAIM=0, no reap-free) ran ALL 320 rounds with NO crash - only the leak (mem_free
23042->5351, ~0.77MB/backend). So the kernel-vfs-object double-free UAF ONLY exists if we REAP-FREE the
fallback set. The recommended overflow-region-with-free-noop design ALSO reclaims via wholesale
destroy_address_space teardown -> it carries the SAME kernel-object-lifetime UAF risk (a shared vnode/
dentry allocated in a child overflow region that OUTLIVES the child AS would be torn down while the
global vnode/dentry cache still references it). NOT obviously safe.

ALL the obvious vfs objects are ALREADY scoped (verified in source): make_file (fs/fs.hh - kernel_heap_
scope), new vnode (vfs_vnode.cc:198), dentry_alloc (vfs_dentry.cc:78), v_data via VFS_VGET (under the
vnode scope), fd_table (kern_descrip.cc:232). So kernel infra is deliberately kept OFF the arena. The
crash object must be either (a) a still-UNSCOPED vfs sub-alloc reached only post-exhaustion, or (b) a
tracker artifact. Since the control arm does not crash, the leak itself is APP-heap-in-the-identity-
fallback, and any RECLAIM mechanism that touches identity-heap objects by AS risks the kernel-object UAF.

## THE HONEST STATE OF LEAK #2 (design decision, not another quick EC2 iteration):
- The LEAK is real + reproduced (control arm, ~0.77-1.8MB/backend -> OOM ~round 280-320).
- FOUR reclaim designs refuted: VA-reclaim (cross-AS VA reuse fault), per-AS-overflow-v1 (cross-AS
  free-by-range header read fault), reap-tracker (kernel-object double-free UAF), bounded-rewind
  (8.8% reclaim, non-viable). All share one wall: you cannot safely reclaim identity-heap fallback
  memory keyed on the child AS because (i) VA reuse crosses the COW boundary and (ii) the fallback set
  is indistinguishable app-vs-kernel in a unikernel and kernel objects have independent lifetimes.
- The RIGHT next move is a DESIGN decision, candidates:
  (1) PREVENT exhaustion for APP allocs: measure the arena OCCUPANTS (app vs any still-unscoped kernel
      allocs). If unscoped kernel allocs consume arena VA, scope them -> more room -> exhaustion delayed.
      But if PURE app heap alone exhausts 512MB under churn, this only delays.
  (2) GROW the arena (bounded stopgap) - honest, simple, buys headroom, does not truly fix unbounded churn.
  (3) A per-AS APP-ONLY sub-arena that is provably app-exclusive (allocated only via the libc malloc
      entry, NEVER the kernel path) - but the unikernel boundary makes "app-only" hard to guarantee.
  (4) Accept the leak as a KNOWN LIMITATION documented on the fork stack, fix leak #1 (done), and note
      leak #2 needs upstream fork-arena redesign - honest if no safe reclaim exists.
- This is worth a THINK/design pass, NOT another rushed build. Leak #1 is banked + solid; leak #2 is
  correctly UNSHIPPED (4 refuted designs is data, not failure).

## LEAK #2 - DESIGN VERDICT (2026-09-16, Plan agent bab137b3, page-table-level analysis):
D5 segment-reclaim UNSAFE (5th refuted design). Fails C1: a fresh child clones the POSTMASTER's arena
PTEs (not AS0's, not the dead child's), so a reissued segment VA is a stale COW-link to the postmaster ->
first write COW-copies the postmaster's LIVE page into the child -> SILENT cross-AS corruption (worse than
a fault). g_bump MONOTONICITY is the load-bearing correctness invariant - segment granularity reissues VA
in bigger units but reissue itself is the wall. C2 also unbarriered (RCU vfs frees fire async on the AS0
quiescent thread after destroy_address_space; no quiescence barrier to piggyback; C3 blocks the required
no-cross-AS-reference proof).
KEY CORRECTION: the arena is mmap_populate (EAGER) - the "lazily faulted" comment is WRONG - and eager is
load-bearing (alloc runs IRQs-off; a demand fault aborts). So GROW costs COMMITTED BOOT RAM, not free VA:
GROW to 4 GiB = 4 GiB committed RAM/guest. Recommend ~1 GiB, gated OSV_FORK_ARENA_SIZE_MB.
NO provably-safe real fix under C1-C4. HONEST PATH: GROW (~1 GiB, gated) + DOC-LIMITATION; record leak #2
as a fork-arena limitation needing an UPSTREAM REDESIGN (candidates documented: per-AS-unmapped-in-AS0 +
BSS-range-check no-op free, still owes the C3 kernel-object-lifetime answer; or lazy-but-fault-safe
population). Full recommendation: .local/leak2/DESIGN-RECOMMENDATION.md.

## LEAK #2 FINAL STATE: root-caused + reproduced + FIVE reclaim designs refuted (VA-reclaim,
## per-AS-overflow, reap-tracker, top-rewind, D5-segment). Correctly UNSHIPPED. The mitigation (GROW ~1GiB
## gated + doc) is a small safe gated change worth banking on the fork stack; the real fix is an upstream
## fork-arena redesign out of scope for a mitigation pass. Leak #1 (fd/gfdt) remains fixed + banked.

## LEAK #2 MITIGATION BANKED (2026-09-16): gh-fork bank/fork-arena-grow-mitigation @ 3b3ab1ac4 (G-signed,
## on bench/leakhunt = leak #1 + fork-fd-table generation). Makes the fork arena boot-tunable via
## OSV_FORK_ARENA_SIZE_MB (MiB, clamped [512..4096]); fixes the wrong "lazily faulted" comment (it is
## eager mmap_populate = committed boot RAM); contains() now bounds against runtime g_end (0 until init).
## This is the HONEST MITIGATION per the design pass: delays exhaustion (~700 backends/512MiB), does NOT
## fix the leak; the real fix is an upstream fork-arena redesign. 2 files, +52/-5.
## *** NOT metal-validated *** - must build + boot + churn-test before a PR is opened (same discipline as
## native-ZFS 4a). The change touches g_end linkage (moved out of the anon namespace to fork_arena scope
## for the header extern) - a build/link check is REQUIRED. Queue a metal validation: build bench/leakhunt
## + this commit, boot, run the churn loop with OSV_FORK_ARENA_SIZE_MB=1024, confirm (a) boots (eager
## 1GiB populate OK on the guest), (b) exhaustion pushed past round 300, (c) no wedge, (d) totalCORRUPT=0,
## (e) the cross-AS-kernel-object-survival probe (no recover magic-mismatch / no mmap_fault in vrele/~file).
## Then open a PR stacked on the fork stack (like leak #1's bank/fork-fd-reap-leak) + a #1458 section.

## LEAK #2 REAL-FIX PUSH + LEAK #1 PR (2026-09-16, operator directive "do (a) push for a real fix"):
Clarified framing: D5 was NEVER code - a design-pass PROPOSAL, rejected on paper. bank/fork-arena-grow-
mitigation is NOT a leak fix - it only DELAYS the OOM (moves it from ~700 to ~1400 backends). Discarded as
the answer. Operator wants the REAL fix.
- Agent e7245ce6 (leak #2 REAL fix, m5d.metal): root-cause FIRST via an app-lifetime-vs-kernel-lifetime
  HISTOGRAM of the leaking fallback allocations (name the exact sites), THEN the fix the data supports:
  if leak is ~all app-heap + a few missed-kernel_heap_scope sites -> (i) scope the missed kernel sites so
  NO cross-AS-lifetime object reaches the arena, (ii) per-AS overflow region with NO-OP free (BSS range-
  check) reclaimed wholesale on reap - SAFE because (i) makes the region app-lifetime-only. Satisfies
  C1/C2/C3. 5-part gate incl the cross-AS-kernel-object-survival probe. Brief: .local/leak2/REAL-FIX-BRIEF.md.
- Agent aab79467 (leak #1 PR): get bank/fork-fd-reap-leak into reviewable shape. Blocker: it depends on
  the shared-gfdt fd-table generation (46333ccea) which is NOT on master + NOT in #1455/#1456 (they carry
  the OLD fd model) + conflicts with #1456. Task: establish the minimal 2-commit unit [46333ccea + the
  reap fix], decide the honest PR target (prefer: propose the fd-table redesign stacked on #1456 as the
  fork fd-handling; else keep in #1458 as a review-ready S-item), build + re-validate, OPEN the PR if
  viable else produce the review-ready branch + precise blocker.
ROOT-CAUSE HYPOTHESIS for the real leak #2 fix (to confirm/refute via the histogram): the leak is the PG
backend's own per-connection APP heap (app-lifetime), which is SAFE to reclaim wholesale on reap; the C3
UAF hazard comes only from a FEW kernel-object sites whose ctor is scoped but whose nested/later-growing
members (dentry name strings, epoll sets, catalog vectors) are NOT - allocated on a child thread outside
the scope -> arena. Scoping those makes the per-AS region app-lifetime-only and the wholesale reclaim safe.

## LEAK #1 PR OUTCOME (2026-09-17, agent aab79467): NOT openable yet - review-ready branch + precise blocker.
The fix modifies release_inherited_fds(), part of the 3-commit shared-gfdt fd-table generation
(8c8f53d2d "child own ref on inherited fds" -> a377258ce "keep shared slot when owner closes inherited
fd" -> f411d5edc "child must not tear a parent-owned fd from the shared table"). That generation has a
HARD build dependency on the fork ARENA (fork_arena::kernel_heap_scope, 9 sites in fork.cc incl the reaper
that calls release_inherited_fds). VERIFIED: #1455 (dce0d32fd) + #1456 (e9a31b1ab) carry NEITHER the gfdt
symbols NOR core/fork_arena.cc - they use the OLDER simpler fd model; cherry-picking the fd-gen onto #1456
conflicts on the missing fork_arena.hh and would not build. The coherent minimal base is wip/fork-clone-scan
(65279b938) = fork base + COW AS + fork arena + gfdt-gen, 136 commits ahead of master, NO open PR.
=> Option 2a (openable PR) NOT viable - base does not exist upstream, cannot reduce to #1455/#1456. Did
NOT open a PR against a nonexistent base (correct discipline).
DELIVERED (Option 2b): gh-fork bank/fork-fd-reap-leak-reviewready (3 commits G-signed: 65279b938 base +
5f45f636f apps repin 57c60798->5cb19033 [the fork-clone-scan pin was a dangling gitlink; pre-push hook
would reject] + 1ae5c2f5e the pure 2-file reap fix +94/-24 probe-stripped). BUILD-VALIDATED: both TUs
compile clean CONF_fork=1; fork_reap_close_child_opened_fd defined in kern_descrip.o, called from fork.o,
OSV_FORK_FD_REAP gate present; source byte-identical to the 400-round-validated ff7f8c0f5 (no metal re-run
needed). #1458 refreshed with the dependency chain + branch + blocker.
BLOCKER (precise): leak #1 lands as one clean commit on top of whichever PR proposes the shared-gfdt
fd-table generation - i.e. gated on the maintainer's pending #1455/#1456 fork-stack composition. It is now
review-ready + pre-validated for that moment. CORRECTION banked: the fd-table generation is exactly 3
commits (not the 5 loosely cited before; 56357aa11/9108df4b5 are separate signal/coherence fixes).

## LEAK #2 REAL-FIX - STEP 1 HISTOGRAM DONE (2026-09-17, agent e7245ce6, box i-0a13d716cee541d70):
DECISIVE root-cause: the leak is APP-LIFETIME. Of leaked-at-reap bytes, 99.87% = PostgreSQL's own heap
(AllocSet/MemoryContext family, VA>=0x100000000000); 0.13% (1.9MB) = kernel libc wrappers. Kernel-LIFETIME
objects freed cross-AS that reach the fallback = 0.056% of fallback, ZERO from kernel sites -> confirms ALL
vfs objects are already kernel_heap_scope'd off the arena. My "missed nested-member scope" hypothesis was
REFUTED by the data (cleanly - no missed kernel sites exist). So step 2(i) scoping is NOT needed; the fix
is just 2(ii): per-AS overflow region, NO-OP free via BSS range-check, wholesale reclaim on reap - SAFE by
the histogram (C3 UAF absent). Proceeding to build + the 5-part gate.
CAUTION steered: 99.87% is an AVERAGE; the 0.056% cross-AS residual is nonzero -> a rare cross-AS UAF is
still a crash. The wholesale reclaim must be safe for the residual too. Gate (d) - the cross-AS-kernel-
object-survival probe - guards it and must pass AT SCALE (300+ rounds), not on-average. If gate (d) trips
even once, the residual is the wall: route those specific allocs to the identity heap (tiny bounded leak)
or report unsafe. Trust the gate, not the 99.87%.

## LEAK #2 REAL FIX - ALL 5 GATES PASS (2026-09-17, agent e7245ce6, box i-0a13d716cee541d70):
The real fix WORKS. Per-AS overflow region (child-private VA, never reissued cross-AS = C1) with NO-OP
free via BSS range-check (never reads a chunk header cross-AS = C2), reclaimed wholesale by
destroy_address_space page teardown on reap. SAFE because the region is app-lifetime-only (histogram
99.87%) AND the one cross-AS class was scoped out (below).
GATES (400 rounds, 26,080 backends reaped):
 (a) mem_free FLAT: ON plateaus 22.5GB while 90GB overflow served (leak GONE); OFF monotonic 23.4->17.1GB
     in lockstep with fb (~0.85MB/backend leak).
 (b) 400 rounds ok=32 fail=0, no wedge/crash/OOM.
 (c) totalCORRUPT=0 all 400 rounds.
 (d) AT SCALE: magic_mm=0, 0 page-faults, 0 vrele/drele/~file/fflush faults across 26,080 reaps - NO
     kernel-lifetime object wholesale-freed (the residual-safety probe, passed at scale not on-average).
 (e) identity fallback fb_mb peaks 16MB (bounded map-miss) vs 17,289MB OFF.
THE RESIDUAL WARNING WAS DEAD ON: the design crashed FIRST (fflush+246, addr 0x308...) - stdio FILE
objects live on a PROCESS-GLOBAL open-file list (ofl_head, kernel static shared cross-AS); a FILE in the
per-AS overflow region faults when fflush(NULL) walks the shared list from another AS. FIXED by scoping
the FILE malloc (libc/stdio/__fdopen.c) to the identity heap - the ONE missed cross-AS class, exactly the
"keep it out of the reclaimable region" path. Also fixed: 32MB eager-populate overflow regions OOM
(overcommit); 1MB regions keep mem_free flat.
BANKING: clean (probe-stripped) commit on gh-fork bank/fork-arena-real-reclaim + a #1458 section,
SUPERSEDES bank/fork-arena-grow-mitigation (which only delayed). This is the REAL leak #2 fix. Same
fork-stack landing dependency as leak #1 (gated on the fork-arena + fd-table generation being proposed).

## LEAK #2 - THE MASKING INSIGHT (2026-09-17, agent e7245ce6) - the most important finding of the arc:
The fork ARENA is COW-mapped in EVERY address space, so a cross-AS raw-pointer access reads a DIVERGENT
COW COPY instead of faulting -> it SILENTLY MASKS latent cross-AS-correctness bugs (a stale/divergent read
is a silent correctness bug, not a crash). The per-AS OVERFLOW region (mapped in ONE AS) turns those same
bugs into HARD faults. So the residual crashes the real-fix hunt surfaced are PRE-EXISTING fork-coherence
gaps the arena was HIDING, not new bugs the fix introduced:
 - FILE (stdio): allocated on a child app thread, linked into the process-global ofl_head open-file list;
   fflush(NULL)/exit-flush from ANY AS walks the shared list -> touches the child's FILE cross-AS. FIX:
   scope the FILE malloc (libc/stdio/__fdopen.c) to the identity heap. Generic fork-correctness fix.
 - net_channel: tcp_setup_net_channel (bsd/sys/netinet/tcp_input.cc:3261) aligned_new<net_channel> WITHOUT
   kernel_heap_scope; the AS0 RX classifier (post_packet->nc->push, non-preemptable IRQ) writes the
   embedded 256-slot ring cross-AS -> preemptable() assert fault at an overflow VA. FIX: scope it. (net_req
   was listed scoped in the design-rec audit; net_channel was MISSED - same family.)
DECIDING QUESTION (shippability): is the cross-AS-touched object set BOUNDED+auditable or open-ended?
Steered: AUDIT the AS0/IRQ/RCU/sibling-touched object graph (enumerate every class a non-allocating context
derefs by raw pointer that a child app thread could allocate post-exhaustion): RX/driver bottom-halves,
RCU-callback-freed objects, process-global intrusive lists (ofl_head + timer/taskq/callout/aio/epoll/
socketbuf), sibling-reachable-via-shared-pipe/socket/shm. If BOUNDED (FILE+net_channel+handful) -> scope
all, re-run clean, PROVABLY-COMPLETE safe fix + generic coherence fixes as bonus. If OPEN-ENDED -> honest
fallback to grow-mitigation + document. Either way each scoping fix is VALUABLE INDEPENDENTLY (fixes a
latent fork-coherence bug the arena masks) - bank them as generic commits regardless.
BROADER IMPLICATION: the arena's mapped-everywhere property may be masking OTHER latent fork-coherence
bugs beyond these two. Worth a note for the fork stack: cross-AS raw-pointer access to child-app-allocated
memory is only "safe" today because the arena serves a divergent copy - which is itself wrong (silent
divergence). The correct invariant is "cross-AS-referenced objects must be on the identity heap" - the
scoping audit enforces it.

## LEAK #2 REAL FIX - COMPLETE (2026-09-17, agent e7245ce6): BOUNDED audit (Outcome A) = the good result.
The cross-AS-touched object set is BOUNDED + fully enumerated: the BSD net stack is scoped wholesale via
uma_stub; the only gaps were per-connection objects allocated with C++ new/aligned_new. All 8 found +
scoped; NO 9th surfaced across 26,181 reaped backends. So this is a PROVABLY-COMPLETE safe fix, not
whack-a-mole.
BANKED: gh-fork bank/fork-arena-real-reclaim (tip 43fcdca79), 2 G-signed commits:
 A. c2e86203a - scope 8 cross-AS-referenced kernel objects to the identity heap (socket, inpcb x3,
    serial_timer_task x6, net_channel, ztx_handle, stdio FILE). GENERIC fork-coherence fix, valuable
    independently (each fixes a latent divergent-COW-copy silent-correctness bug the arena masks).
    8 files: uipc_socket/uipc_syscalls/raw_ip/tcp_input/tcp_timer/tcp_usrreq/udp_usrreq/__fdopen.
 B. 43fcdca79 - per-AS COW-private overflow region (slot 97) + NO-OP free via BSS range-check + wholesale
    reclaim on destroy_address_space + preemptable-context guard + 1MiB regions + env gate
    OSV_FORK_ARENA_RECLAIM. 152 lines fork_arena.cc.
5-GATE VALIDATION (400 rounds, 26,181 backends, A/B on the env gate) - ALL PASS: (a) mem_free FLAT while
90GiB overflow served vs monotonic drop off; (b) no wedge/crash/OOM; (c) totalCORRUPT=0; (d) 0 magic-mm /
0 cross-AS fault at scale; (e) fallback bounded 16MB vs 17,289MB off. #1458 updated (mechanism + masking
insight + bounded audit + 5-gate table + supersedes the grow-mitigation).
PRE-PR CLEANUP ITEM (not this fix's bug): leak_probe_stats() is a PRE-EXISTING probe on the bench/leakhunt
BASE (not added by this fix, 0 callers) - must be stripped from the base before EITHER leak fix becomes a
real PR. Both leak fixes share the bench/leakhunt lineage; the probe is base cruft to clean at PR time.
STATUS: leak #2 = REAL FIX, validated, banked. Supersedes grow-mitigation. Same fork-stack landing
dependency as leak #1 (gated on the fork-arena + fd-table generation being proposed as a PR).
