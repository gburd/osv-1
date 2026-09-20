# VU64 wall - FINAL VERDICT (2026-09-19, agent bd33fb55): a per-backend fork-footprint OOM COST, not a bug.

## Account: cwwake boxes TERMINATED, 0 orphans, 0 volumes, SG /32 intact, solnix untouched.

## THE CHAIN (each step measured, several prior hypotheses refuted by data):
1. Reproduced the VU64 wedge (worker, cliff ~t=45-75s, never recovers).
2. The zcw_done=1 + waiter-asleep "smoking gun" was a RECLAIM-STALL SYMPTOM, NOT a lost wakeup - proven by
   SIX wake-path A/Bs ALL still wedging: FLUSH_INLINE, CONDVAR_NO_MORPH, WAKE_IPI_ALWAYS v1, v2+mask-bypass,
   ZIL_WAIT_TIMEOUT (1ms recheck), IDLE_SPIN=2e9 (no-halt). None addressed the real cause.
3. Real cause (clean console): "Out of memory: could not reclaim any further. Current memory: 2868 Kb",
   abort in memory::reclaimer::do_reclaim, network-dead after = OOM PANIC.
4. Pool named (per-pool MEMPROBE): free collapses 64GB->0.5GB; ARC innocent (<=2GB, and ARC=8G-cap A/B
   still OOMs); dirty innocent (3.2GB cap); ~42GB is anon/per-backend PRIVATE across 74 fork-child ASes
   (~0.6-0.8GB/backend).
5. BUG-vs-COST settled by the shared_buffers A/B: sb=16G OOMs at t~45s; sb=1G runs VU64 TO COMPLETION
   (Test complete, 17GB free floor). Per-backend footprint present at BOTH sb sizes -> shared_buffers is
   CORRECTLY SHARED across fork (OSv shared_anon_registry works, NOT COW-duplicated). So NOT a MAP_SHARED
   coherence bug. OOM = base(shbuf + ARC + kernel) + N_backends x per-backend-private > 64GB guest.

## VERDICT: COST, not a bug. The VU64 wall is an INHERENT OSv-fork PER-BACKEND MEMORY FOOTPRINT
## (~0.6-0.8GB/backend: COW page-table clone + per-AS private anon heap/stacks/arena) that is LARGER than
## Linux's per-backend fork footprint. Concurrency-proportional: VU32(~40 bk) fits 64GB, VU64(~74 bk) does
## not. Linux scales same host because its per-backend fork footprint is smaller (shared page tables, no
## per-AS COW-arena). This is a MEMORY-MANAGEMENT characteristic of the OSv fork model, NOT a scheduler/
## wake/ZIL bug.

## LEVERS (the honest next options - a G2 memory-management improvement, not a quick fix):
- Immediate MITIGATION (no code): size guest RAM to base + N x ~0.7GB + headroom (sb=1G proves VU64
  completes). i.e. a 64GB guest supports ~VU32-48; VU64 needs more RAM or smaller shared_buffers.
- Real IMPROVEMENT (harder, generic G2): reduce OSv's per-backend fork footprint - the COW page-table
  clone cost + the per-AS private anon (fork-arena + stacks + heap). Every forked backend pays ~0.7GB;
  shrinking that raises the max-backends a given RAM supports. This is the OSv fork model's memory cost,
  the same fork machinery the leak fixes + coherence scopings touched. A dedicated fork-footprint-reduction
  study, not a one-liner.
- Or accept a documented lower max_connections-per-GB on OSv than Linux (honest fork-model tradeoff).

## THE HONEST M1 SCALING PICTURE (final, measured):
  VU8/16 : OSv FASTER than Linux (1.17x / 1.29x).
  VU32   : idle->wake tail FIXED (#1511 adaptive-idle-spin, upstream); median ~0.6-0.7x Linux (the gap is
           NOT the idle->wake tail and NOT a lost wakeup - re-examine: is it also per-backend-footprint
           memory pressure at VU32, or a throughput factor? OPEN, but NOT a wake bug).
  VU64+  : OOM at ~74 backends on the ~0.7GB/backend OSv-fork footprint. Linux scales (smaller footprint).
           A memory-management cost/improvement, NOT a scheduler wake bug.
## The wakeup-deficit theory for VU64 is RETIRED (6 A/Bs refuted it + the OOM console proves memory).
## adaptive-idle-spin (#1511) stands on its OWN merit (idle-safe + idle->wake tail); it was never claimed
## to fix VU64 and does not. The VU64 residual is now correctly named: OSv fork per-backend memory footprint.

## LESSON (banked): a wedge that looks like a lost-wakeup/deadlock (all backends on one lock, zero IO, idle
## CPU) can be an OOM/RECLAIM STALL - the reclaimer spins unable to free, holders/waiters block, IO stops.
## ALWAYS check free-mem + the console for OOM/panic BEFORE concluding "lost wakeup". zcw_done=1 was
## necessary-not-sufficient. Six wake-path A/Bs were spent chasing a symptom before the console named it.
