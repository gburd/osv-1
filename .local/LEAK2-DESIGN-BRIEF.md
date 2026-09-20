# LEAK #2 design brief - the fork-arena VA-exhaustion -> identity-heap physical leak (needs a design pass)

## THE BUG (fully characterized, reproduced, 4 fix designs refuted by measurement)
Two-layer:
1. TRIGGER: fork_arena g_bump is a GLOBAL MONOTONIC cursor (512MB). release_as() drops a dead child's
   per-AS freelist SLOT but NEVER returns its carved VA to g_bump ("No teardown needed for the shared
   bump pointer"). The per-AS freelist only recycles WITHIN a live AS; a FRESH backend starts empty and
   bump-carves NEW VA. So each backend permanently consumes its peak arena footprint off g_bump forever.
   ~512MB / ~0.7MB-peak-per-backend ~= 700 backends -> arena VA EXHAUSTED.
2. LEAK: post-exhaustion, alloc() returns nullptr and std_malloc falls through to the IDENTITY heap for
   ALL app allocations of ALL future backends. Identity-heap objects are shared verbatim in every AS,
   NOT tied to the child AS, so destroy_address_space NEVER frees them -> ~0.77-1.8MB/backend PHYSICAL
   leak -> mem_free 23GB->5GB -> OOM ~round 280-320.

## THE WALL (why reclaim is hard - 4 refuted designs, all measured on metal):
- VA-reclaim (return dead VA to a global pool, reissue cross-AS): CRASH - a reissued VA is not present/
  consistent in the new child's COW-cloned page tables -> mmap fault.
- per-AS overflow region v1 (child bumps its own region, per-chunk free): CRASH - free() from AS0/a
  sibling reads the chunk's size/class HEADER at a VA mapped only in the dead child -> page fault.
- reap-tracker (track child-AS identity-heap fallbacks, free on reap): CRASH (UAF) - in a UNIKERNEL the
  kernel runs on the app thread, so kernel vfs objects (vnode/dentry/file sub-allocs) allocated during
  a child's syscall are indistinguishable from app heap at the malloc boundary; reap-freeing them double-
  frees vs the kernel's own RCU/refcount path. CONTROL (no reap-free) ran clean -> crash was tracker-induced.
- bounded g_bump top-rewind: NON-VIABLE - carve pattern is interleaved not LIFO; top-rewind reclaims 8.8%
  (reap_top=6 vs reap_buried=271).

## KEY CONSTRAINTS (invariants proven, must hold for ANY design):
- C1: NEVER reissue a VA carved by AS-A to a different AS-B while B's page tables are COW-cloned from a
  DIFFERENT ancestor - the reissued VA faults (VA-reclaim crash).
- C2: free() CROSSES AS (AS0/reaper/sibling/RCU frees objects a child allocated). So free() must NOT read
  a chunk header at a VA that is only mapped in the (now-dead or other) child (per-AS-overflow crash).
- C3: You CANNOT distinguish app-heap from kernel-heap allocations at the low-level malloc boundary in a
  unikernel (kernel on app thread). So no reclaim keyed on "app thread + child AS" is safe - it captures
  kernel objects with independent lifetimes (tracker UAF).
- C4 (mitigant): the known fork-hazard vfs allocs ARE already scoped to the kernel heap (make_file, new
  vnode, dentry_alloc, v_data). So MOST kernel infra is off the arena; the post-exhaustion fallback set
  is MOSTLY app heap - but "mostly" is not "provably all" (C3).

## CANDIDATE DESIGNS FOR THE PASS (rank for safety + effectiveness):
D5 (SEGMENT reclaim): carve the arena in fixed SEGMENTS (e.g. 2MB). A live AS owns whole segments; on
   release_as return its segments WHOLE to a global free-SEGMENT list; a fresh AS draws whole segments.
   Per-AS chunk freelists as today. Question that decides safety: does free() ever touch a chunk in a
   segment that has been REISSUED to a new AS while an old cross-AS reference (C2/C3: AS0/RCU freeing a
   kernel object) still points into that segment's VA? If a segment is only reissued AFTER its owning AS
   is fully destroyed AND all cross-AS frees of its objects have drained, safe. Needs an RCU-grace /
   quiescence barrier before reissue. THIS is the crux - analyze it.
GROW (stopgap): enlarge the arena (e.g. 512MB->4GB) - buys ~8x headroom, honest, does NOT fix unbounded
   churn but makes the wedge take ~5600 backends instead of ~700. Cheap, safe, shippable as a mitigation.
SCOPE-MORE: measure arena occupants (app vs any still-unscoped kernel alloc); scope leftover kernel allocs
   to free arena room. Only delays if pure app heap alone exhausts.
DOC-LIMITATION: if no safe reclaim exists, document leak #2 as a known fork-arena limitation needing an
   upstream redesign; ship leak #1 (done) + GROW as mitigation.

## STATUS: leak #1 FIXED+banked. leak #2 correctly UNSHIPPED (4 designs refuted = data). Next = a DESIGN
## pass (not a rushed build) to evaluate D5's RCU-quiescence-before-segment-reissue safety, else GROW as
## an honest mitigation. All evidence in .local/leak2/RESULT.md + {ON,OFF,CARVE}-*.log.
