# LEAK #2 REAL-FIX brief - root-cause the leak precisely, then fix it safely (NOT the grow mitigation)

## The mitigation (bank/fork-arena-grow-mitigation) is NOT a fix - it only DELAYS the OOM. Discard it as
## the answer. We want a REAL fix that makes sustained fork churn leak-free. Operator directive: push (a).

## WHAT IS ACTUALLY LEAKING (must be pinned precisely first - do NOT assume)
Measured: ~0.77 MB/reaped-backend, monotonic mem_free drop, per-FORK (bare SELECT-1 churn leaks it), only
AFTER the 512MB fork arena's g_bump exhausts (~700 backends). Pre-exhaustion: FLAT (arena backends free
clean via release_as page teardown). So the leak = post-exhaustion allocations that fall through to the
IDENTITY heap (shared verbatim in every AS, not AS-tied, never freed on reap).

TWO SUB-QUESTIONS THE FIX MUST SEPARATE (the prior hunts conflated them):
1. THE LEAK ITSELF: is the leaking memory the PG backend's own APP heap (per-connection relcache/catcache/
   memory contexts) - app-LIFETIME, dies with the backend - that only leaks because it landed in the
   identity fallback instead of the arena? If so, the fix is: DO NOT fall to the identity heap - keep app
   allocations in a reclaimable-on-reap region. That region is safe to tear down wholesale IFF it holds
   only app-lifetime objects.
2. THE C3 HAZARD: does ANY cross-AS-LIFETIME object (a kernel vnode/dentry/file, or a sub-allocation of
   one, shared in a global cache and freed later by RCU/a sibling) ALSO land in the arena/fallback during
   a child's syscall? If yes, wholesale reap-teardown of the child region frees a still-referenced kernel
   object -> UAF (this is what crashed the reap-tracker). The design pass found the top-level vfs objects
   (make_file/new vnode/dentry_alloc/v_data/fd_table/f_epolls/net_req/blk_req) ARE scoped to the identity
   heap via kernel_heap_scope. So the residual C3 objects, IF ANY, are likely NESTED/LATER-GROWING members
   NOT covered by the ctor-time scope (a dentry name string appended after alloc, an epoll set that
   reallocs, a catalog vector that grows) - allocated on a child thread OUTSIDE any scope -> arena.

## STEP 1 - ROOT-CAUSE precisely (instrument, do not guess): on the exhausted-arena / identity-fallback
path, LOG THE CALLER (return address / symbolized backtrace) of every allocation that lands there during
a child syscall. Classify by whether the object is later freed by (a) the backend itself before exit
(app-lifetime, safe to reclaim on reap) vs (b) a cross-AS path - the RCU quiescent thread / a sibling /
AS0 (kernel-lifetime, NOT safe to wholesale-free). Produce the HISTOGRAM: what fraction of the leaked
bytes is app-lifetime vs kernel-lifetime, and NAME the specific kernel allocation sites still reaching the
arena (the missed-scope sites). THIS is the root cause, precise.

## STEP 2 - THE FIX depends on what Step 1 finds:
- IF the leak is ~all APP-lifetime and the residual kernel objects are a few NAMED missed-scope sites:
  the REAL FIX has two parts, both root-cause:
  (i) SCOPE the missed kernel-object sites (wrap the nested/later-growing member allocs in
      kernel_heap_scope, or allocate the whole object graph under one scope) so NO cross-AS-lifetime object
      ever reaches the arena. Verify with the Step-1 histogram going to 0 kernel-lifetime-in-arena.
  (ii) Then the arena/per-AS region holds ONLY app-lifetime allocations, so it is SAFE to reclaim on reap.
      Implement the design-pass redesign candidate (a): a per-AS overflow region (child-private VA) whose
      free() is a NO-OP recognized by a BSS-recorded per-AS range check (never reads the possibly-unmapped
      chunk header cross-AS - the fault that crashed per-AS-overflow-v1), reclaimed WHOLESALE by
      destroy_address_space page teardown on reap (the mechanism release_as already uses). Now safe because
      (i) guarantees no kernel-lifetime object is in it. This makes sustained churn LEAK-FREE (each reaped
      backend returns its whole overflow region), the real fix.
- IF the leak includes substantial kernel-lifetime objects that CANNOT be cleanly scoped off: then wholesale
  reclaim is unsafe and the honest fix is different - report that and propose the alternative (e.g. the
  identity-heap fallback allocations get individually refcounted/freed only for the app-lifetime subset, or
  a genuinely different arena design). Do NOT ship an unsafe wholesale-free.

## HARD CONSTRAINTS (proven; any fix MUST satisfy - each killed a prior design):
- C1: never REISSUE a VA carved by AS-A to a different AS-B (reissued VA is a stale COW-link to the
  postmaster in a fresh child -> silent corruption/fault). A per-AS region is fine IF it is never reissued
  to another AS and its VA is unmapped-in-AS0/torn-down on reap.
- C2: free() CROSSES AS - must NOT read a chunk header at a VA mapped only in the dead/other child. Hence
  the NO-OP free via BSS range-check (bounds in BSS = coherent everywhere; page never touched).
- C3: cannot distinguish app-vs-kernel allocations at the malloc boundary (kernel runs on app thread). So
  the fix must ensure kernel-lifetime objects NEVER enter the reclaimable region (via scoping, part (i)),
  NOT try to filter them at free/reap time.
- Eager mmap_populate is load-bearing (alloc runs IRQs-off; demand fault aborts). A per-AS overflow region
  must also be pre-faulted OR only allocated-from in preemptable context - verify.

## VALIDATION (the 3-way gate + the C3 probe, ALL required):
(a) mem_free FLAT over 300+ rounds sustained churn (leak GONE, not delayed) - fix on; monotonic drop - off.
(b) NO wedge/crash to round 300+ (32 conns, autovacuum on).
(c) totalCORRUPT=0 (8KB-unique-payload md5 + prefix-bleed harness - the existing integ.sh check).
(d) cross-AS-kernel-object-survival probe: a child opens a file / registers epoll / sends via a shared
    socket, exits; the RCU quiescent thread later runs file::~file/vrele/drele; assert NO fork_arena
    recover magic-mismatch and NO handle_mmap_fault in that backtrace across 300 rounds. This is THE proof
    that no kernel-lifetime object is being wholesale-freed. It must pass, or the fix is unsafe.
(e) A/B env-gated (e.g. OSV_FORK_ARENA_RECLAIM default on, =0 = old leak) so the leak-gone-vs-leak A/B is
    demonstrable.

## Substrate: m5d.metal lava us-east-2 Debian 12, raw NVMe passthrough, base gh-fork bench/leakhunt (leak
## #1 fd fix + probe), apps 3f93f43, bench-base-gate PASS. Reuse .local/leak2/{host-setup,build-image,
## boot,integ,churn}.sh. Read .local/leak2/{DESIGN-RECOMMENDATION,LOCALIZED,RESULT}.md +
## .local/DECLINE-ROOT-CAUSE-FOUND.md first. This is the REAL fix - do the root-cause histogram FIRST
## (it decides which fix), do not jump to a design. Refute my app-lifetime hypothesis if the data says so.
