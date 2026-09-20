# LEAK #2 DESIGN RECOMMENDATION - fork-arena VA-exhaustion physical leak

Read-only design pass (agent bab137b3, Plan mode). No code changed, no EC2. Verdict derived from
source (page-table level) + the prior measured refutations.

## TL;DR
- **D5 (segment reclaim): UNSAFE** - fails C1 on a mechanism the per-chunk version never reached, and
  has no clean C2 answer. Whole-segment granularity does NOT change the page-table/COW hazard; it makes
  it WORSE (silent cross-AS corruption instead of a fault).
- **No design satisfies C1-C4 for real reclaim.** FIVE now refuted: VA-reclaim, per-AS-overflow,
  reap-tracker, top-rewind, D5-segment.
- **Recommendation: GROW (bounded ~1 GiB, gated) + DOC-LIMITATION.** Ship an enlarged arena as an honest
  documented interim; record leak #2 as a fork-arena limitation needing upstream redesign.
- **KEY correction: the arena is `mmap_populate` (EAGER), not "lazily faulted" (the header comment is
  WRONG).** Eager populate is load-bearing (alloc() runs from IRQs-off contexts; a demand fault would
  abort). So 512 MiB = committed boot RAM; GROW to 4 GiB = 4 GiB committed RAM at boot. Size to ~1 GiB.

## 1. D5 SEGMENT RECLAIM - UNSAFE (fails C1; C2 unbarriered)
Three page-table facts settle C1, none care about chunk-vs-segment granularity:
1. The arena master mapping lives in AS0 and is NEVER torn down (init() map_anon 512MiB
   mmap_fixed|mmap_populate in AS0, never munmap). Every arena VA is always present + RAM-backed in AS0.
2. A fork child does NOT clone AS0's arena PTEs - it clones the PARENT (postmaster)'s. clone_address_space
   deep-copies the parent's app-slot subtree (incl arena slot 96) marking the parent's private leaves COW.
   So at fork the child inherits, per arena VA, the postmaster's CURRENT PTE: COW-present where the
   postmaster touched it, empty where it did not.
3. On child destroy only the child's PRIVATE (non-COW) arena pages are freed; COW/shared leaves stay.
   release_as clears the BSS freelist slot; the carved VA is never returned = the leak.

Why D5 fails C1: a fresh child B is COW-cloned from the POSTMASTER (not the dead child A that owned the
segment, not AS0). For any segment VA the postmaster ever wrote, B inherits a COW-present PTE -> B's
allocator draws the "free" segment, bump-carves, and the first write (the chunk-header store) is a COW
write fault that copies the POSTMASTER's live page into B. B is silently seeded with a copy of the
postmaster's arena bytes; untouched VAs are empty (demand fault). The segment is a mix of
{COW-to-postmaster, empty} PTEs - never a clean zero-fill. This is WORSE than the per-chunk crash:
silent cross-AS data bleed with no fault (exactly the AllocSetReset next-pointer-clobber the per-AS
freelist was built to prevent). LOAD-BEARING INVARIANT: a VA carved off g_bump is safe to share across AS
ONLY because it is globally unique and never reissued. g_bump monotonicity IS the correctness property.
Segment granularity does not restore uniqueness. C1 killed.

Why C2 also kills it: free() dispatches by ADDRESS (if fork_arena::contains(p) -> recover(p) reads the
chunk header at p) in WHATEVER AS the freeing thread runs in - and free crosses AS (AS0 reaper / sibling /
RCU). The on-record crash is cpu_quiescent_state_thread -> file::~file -> drele/vrele: RCU-deferred frees
fire on the AS0 quiescent thread ASYNC and AFTER destroy_address_space. There is NO existing quiescence
barrier between release_as and a re-carve to piggyback. A correct one would need rcu_synchronize-after-
destroy PLUS a global no-live-cross-AS-reference proof that C3 (shared-everything unikernel) makes
unattainable. C2: no barrier + C3 blocks the required proof.

## 2. GROW - SAFE, shippable, cost is RAM not VA
Finding: fork_arena.hh comments "512 MiB of VA (lazily faulted)" - WRONG. init() maps mmap_populate
(EAGER), and the adjacent comment says this is load-bearing for CORRECTNESS: alloc() can be entered
IRQs-off/preempt-off, where a demand fault trips assert(preemptable && irq_enabled) -> abort. So the arena
MUST be pre-faulted -> 512 MiB is committed RAM at boot; GROW to 4 GiB = 4 GiB committed RAM forever, per
guest. Benefit: exhaustion at ~0.7 MiB/backend -> 512MiB~700 backends; 1GiB~1400; 2GiB~2800; 4GiB~5600.
Trivial (moves g_end), cannot add a UAF. Does NOT fix unbounded churn - honest delay only.
RECOMMENDED: grow to ~1 GiB (not 4), env-gated OSV_FORK_ARENA_SIZE_MB (default 512 or 1024 after a
boot-RAM check), and FIX the misleading "lazily faulted" comment.

## 3. SCOPE-MORE - no NEW unscoped site found
The known fork-hazard vfs objects are ALL already scoped off the arena (C4 confirmed): make_file
(fs/fs.hh:62), new vnode + v_data via VFS_VGET (vfs_vnode.cc:198), dentry_alloc (vfs_dentry.cc:78),
fd_table (kern_descrip.cc:232), f_epolls (kern_descrip.cc:462), net_req/blk_req/signals/wait_records/
thread-stacks/atfork/pipe/sem/shm - all scoped. The tracker-reap crash was tracker-induced double-free,
NOT an unscoped site (control ran clean). SCOPE-MORE alone cannot prevent exhaustion (pure app heap
exhausts 512 MiB - measured). The residual C3 gap ("mostly not provably all app heap") is a reason NOT to
attempt any AS-keyed reclaim.

## 4. RANKED RECOMMENDATION
1. GROW (~1 GiB, gated) + DOC-LIMITATION - SAFE, delays only, SHIP as interim.
2. SCOPE-MORE audit / a magic-mismatch COUNT path (measurement not assert) - SAFE, no fix, optional pair.
- D5 segment reclaim - NO (C1, C2).
- VA-reclaim / per-AS-overflow / reap-tracker / top-rewind - NO (refuted).

THE HONEST PATH: no provably-safe real fix under C1-C4. The wall is now understood at the page-table
level: g_bump monotonicity is the load-bearing correctness invariant. Ship GROW as a bounded documented
mitigation; record leak #2 as a fork-arena limitation needing an UPSTREAM REDESIGN. Redesign candidates to
DOCUMENT (not build now): (a) a per-AS arena fully UNMAPPED in AS0 on release_as whose frees are no-ops via
BSS range-check (never touch the possibly-unmapped page) - still must answer the C3 kernel-object-lifetime
question, hence a redesign; (b) make arena population lazy-but-fault-safe so growth is free VA not RAM.

## NEXT BUILD RUN (mitigation, one small gated change):
1. arena_size via OSV_FORK_ARENA_SIZE_MB (default 512 or 1024 after boot-RAM check); keep mmap_populate.
2. Fix the fork_arena.hh "(lazily faulted)" comment -> "(eagerly populated - committed RAM at boot)".
3. #1458 doc section: leak #2 = fork-arena VA exhaustion -> identity-heap physical leak; 5 refuted reclaim
   designs; g_bump-monotonicity-is-load-bearing; GROW interim; upstream redesign needed.
VALIDATE - the 3-way gate PLUS a cross-AS-kernel-object-survival probe:
 (a) mem flat + exhaustion pushed past the churn budget (no exhaustion through round 300 at 1 GiB).
 (b) no wedge to round 300 (32 conns, autovacuum, ok=32 every round, no abort).
 (c) totalCORRUPT=0 (8KB-md5 + prefix-bleed harness).
 (d) NEW: cross-AS kernel-object survival - a child opens a file/epoll/socket, exits, the RCU quiescent
     thread later runs file::~file/vrele; assert NO fork_arena::recover magic-mismatch and NO
     handle_mmap_fault in the vrele/drele/~file backtrace across 300 rounds. GROW touches only g_end so
     this passes by construction; keep it as a PERMANENT regression guard on the "all cross-AS-freed
     kernel objects stay off the arena" invariant every future reclaim must not break.

## Critical files
core/fork_arena.cc (init mmap_populate = GROW cost; alloc/free/recover by-address = C2; release_as = the
leak), include/osv/fork_arena.hh (size/base knob + wrong "lazily faulted" comment), core/mmu.cc
(clone_address_space child clones postmaster COW arena PTEs = C1; destroy_address_space/release_as;
handle_cow_write_fault = why reissue silently COW-links), core/rcu.cc (cpu_quiescent_state_thread = C2's
missing barrier), core/mempool.cc (std_malloc arena routing + by-address free = C3).
