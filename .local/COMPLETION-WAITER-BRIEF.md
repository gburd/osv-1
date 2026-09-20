# Completion->waiter lost-wakeup deadlock: root-cause brief (the DOMINANT M1 residual)

## THE BUG (measured, fully discriminated in the gates run - see .local/VU64-WEDGE-FINDING.md)
At VU64 OSv/PG-on-ZFS hits a PERMANENT, OSv-SPECIFIC lost-wakeup DEADLOCK on the WAL-commit /
ZIL-completion -> waiter path: healthy ~60s (110-116k commit/15s, NVMe 58-97%, CPU-saturated) then falls
off a cliff at t~75s to commit_delta=2/15s, NVMe=0, qemu ~45% one core (idle), ~66/69 backends stuck on
LWLock:WALWrite, and NEVER recovers (5 min). Discriminated: (a) true deadlock not stall, (b) NOT
io_uring-specific (worker wedges identically -> the ZFS-ZIL/WAL-commit completion->waiter path, not
core/io_uring.cc), (c) NOT adaptive-idle-spin-caused (fixed wedges too -> pre-existing), (d) OSv-SPECIFIC
(Linux on the identical stack scales to 486k, no wedge). This ALSO caps the OSv VU32 MEDIAN at ~0.62x
Linux (it is the DOMINANT residual, not just a VU64 wedge). adaptive-idle-spin (idle->wake) does NOT and
cannot fix it (different layer: completion->waiter).

## THE PATH (local source recon - the completion->waiter chain in OSv)
ZFS ZIL commit: a backend's fsync blocks in zil_commit -> zil_commit_waiter, waiting on
zil_commit_waiter_t.zcw_cv (bsd/sys/cddl/contrib/opensolaris/uts/common/fs/zfs/zil.c). The lwb write +
flush completion (zio done / lwb_write_done / lwb_flush_vdevs_done) is supposed to call
zil_commit_waiter_done -> cv_signal/cv_broadcast(zcw_cv) to wake the blocked backend, which then releases
WALWrite and lets waiters progress. cv_signal/cv_broadcast map (bsd/sys/cddl/compat/opensolaris/sys/
kcondvar.h) to OSv condvar_wake_one / condvar_wake_all -> thread::wake -> (cross-vCPU) send_wakeup_ipi.
HYPOTHESIS: under VU64 concurrency the completion-side cv_signal/broadcast is LOST (the waiter is added to
the cv's wait list AFTER the signal fires, or the wake targets a thread that has parked/halted and the
signal is dropped, or a missing seq-cst fence between the enqueue and the completion's list-check) so the
backend never wakes, never releases WALWrite, and everyone deadlocks. Same cross-vCPU-wakeup ROOT as the
whole arc, at the completion->waiter layer.

## PRIOR ART (do NOT re-derive - build on it)
- modules/open_zfs/patches/0030-zfs-probe-Lever-1-A-B-for-the-post-commit-ZIL-wakeup.patch: a PRIOR
  investigation of exactly the post-commit ZIL wakeup (collect waiters under zl_lock, drop zl_lock, run
  zil_commit_waiter_done). READ IT - it has the lock-ordering + the wakeup-batching context.
- modules/open_zfs/FINDINGS-osv-openzfs.md documents a SAME-CLASS lost-wakeup (raidz_reflow: "timing-
  sensitive lost-wakeup on vre_cv, raidz_reflow_write_done cv_signal vs the zthr cv_wait throttle loop,
  same class as Bug 1"). So OSv's condvar has a KNOWN lost-wakeup failure mode under ZFS completion cv's.
  Bug 1 (whatever it was) + this raidz one + the ZIL VU64 wedge may share ONE root: an OSv condvar
  signal/wait race on the ZFS completion path. Find Bug 1's writeup + whether it was fixed.
- The OSv condvar itself: core/condvar.cc + include/osv/condvar.h - the wait/signal/wake_one/wake_all.
  Is there a signal-before-wait race, or a wake targeting a thread whose state transitioned (parked/
  halted/migrated) so the wake is dropped? That is the classic lost-wakeup.

## THE ROOT-CAUSE APPROACH
1. REPRODUCE the VU64 wedge (fresh-boot, io_uring OR worker - both wedge, worker may be easier to trace,
   200wh, VU64). Confirm the signature (healthy->cliff@~75s->commit=2/NVMe=0/idle/WALWrite-pileup, never
   recovers). This is deterministic-ish (~60-75s in) so it is reproducible on one boot.
2. At the wedge, capture the FULL state: which thread holds WALWrite (the WAL-writer backend); what is IT
   blocked on (zcw_cv in zil_commit_waiter?); is there an lwb whose zio/flush COMPLETED (the completion
   ran) but the cv_signal did NOT wake the waiter (the waiter is still on the cv wait-list with zcw_done
   unset)? That is the smoking gun: completion ran + waiter still asleep = lost wakeup.
3. LOCALIZE the race: instrument the zil_commit_waiter enqueue vs the completion's cv_signal/done. Is it
   (a) signal-fires-before-waiter-enqueued (missing the "check zcw_done under the lock before waiting"
   pattern), (b) a missing memory fence between enqueue and the completion's list scan, (c) an OSv
   condvar_wake_one/all dropping a wake to a thread mid-state-transition, or (d) the completion running on
   a taskq/zio thread whose cross-vCPU wake to the halted backend is lost? The io_uring-vs-worker A/B
   already ruled out io_uring; narrow to the ZIL/cv layer.
4. FIX at root: the missing fence / the check-done-before-wait / the wake-a-transitioning-thread bug -
   whichever the instrumentation names. General ZFS-on-OSv / OSv-condvar correctness fix. Env-gate if risky.
5. VALIDATE: the VU64 wedge GONE (fresh-boot VU64 runs to completion with real NOPM, no cliff, matched or
   near Linux), AND re-check VU32 (does fixing the completion->waiter deficit ALSO lift the VU32 median
   toward Linux, since it is the same dominant residual?), AND VU128/192 (does OSv now scale up the range?).
   p99. matched Linux for the ratio.

## SUBSTRATE: hotdog (585335547908, us-east-2, --region explicit), quota 1152 GRANTED, keypair osv-hotdog,
## SG sg-0a0fec26afe57cd43 (osv-bench, ALREADY /32-scoped to 73.4.58.126 - NEVER 0.0.0.0/0, NEVER widen),
## subnet us-east-2a subnet-04a66ccb68b2a2f13, Debian 12 ami-0dc1629a58a7d6458. Base bank/fork-arena-real-
## reclaim (all fixes, gate-PASS) + optionally the adaptive-spin (does not matter - the wedge is
## completion->waiter, orthogonal). apps 3f93f43. Raw NVMe passthrough. NEVER SIGKILL qemu mid-CHECKPOINT.
## hotdog is SHARED with solnix (Owner=gregburd) - only touch Owner=agent-* resources WE create.

## DISPATCHED: agent bd33fb55 (Owner=agent-cwwake) on hotdog. Root-cause the ZIL completion->waiter
## lost-wakeup: reproduce VU64 wedge -> capture the completion-ran-but-waiter-asleep smoking gun ->
## localize the race (signal-before-wait / missing fence / OSv-condvar-wake-to-transitioning-thread /
## taskq-cross-vCPU-wake-lost) -> fix at root -> A/B (wedge gone + does VU32 median lift + VU128/192 scale).
## Prior art flagged: patch 0030 (post-commit ZIL wakeup) + the raidz_reflow same-class lost-wakeup +
## Bug 1. Bank bank/zil-completion-wake-fix.

## PROGRESS (agent bd33fb55): wedge REPRODUCED (worker VU64, cliff t=75s, 66 on WALWrite, never recovers).
## A/B REFUTES the taskq-hop theory: OSV_ZIL_FLUSH_INLINE=1 (patch 0040, collapses flush-completion taskq
## hops) STILL wedges identically -> the lost wake is at the OSv condvar/thread::wake layer, NOT the flush
## pipeline. Focus = hypothesis c (wake to a transitioning/halted thread).
## MAIN-AGENT LOCALIZATION: send_wakeup_ipi() suppresses the IPI when (idle_poll || runqueue.size()>1). The
## completion->waiter case breaks the runqueue>1 assumption: a HALTED target CPU (idle-spin exhausted ->
## wait_for_interrupt, idle_poll=false) with runqueue>1 gets its wake IPI SUPPRESSED - but a halted CPU
## does NOT self-reschedule, so the woken waiter sits in incoming_wakeups UNSEEN = LOST WAKEUP. The guard
## conflates "busy running" with "queued-but-halted". At VU64 (66 backends) that racy combination is common.
## STEERED: (1) decisive FAST A/B - force send_wakeup_ipi to ALWAYS send (OSV_WAKE_IPI_ALWAYS=1); if the
## VU64 wedge DISAPPEARS, the suppression guard IS the root; if it still wedges, deeper (thread::wake
## state-transition race / halt-vs-enqueue ordering + missing fence in do_idle's pre-halt runqueue check).
## (2) smoking-gun probe: at the zcw_cv completion wake, log SEND-vs-SUPPRESS branch + target idle_poll +
## runqueue.size(); catch a suppressed-wake-to-a-halted-target while the waiter stays asleep = proven.
## FIX (if confirmed): drop/narrow the runqueue<=1 suppression (always IPI a non-idle-polling target, or a
## real halted-flag), OR close the halt-vs-enqueue race in do_idle (re-check incoming_wakeups + fence
## after clearing idle_poll, before wait_for_interrupt). GENERAL OSv scheduler correctness fix (any
## cross-vCPU wake to a halted-but-loaded CPU), NOT ZFS-specific. Bank bank/zil-completion-wake-fix (or
## bank/sched-halted-wake-fix if it is the send_wakeup_ipi guard).

## SMOKING GUN PROVEN (agent bd33fb55): "ZWEDGE LOST-WAKE zcw_done=1, waiter asleep 418ms" - the ZIL
## completion RAN (zcw_done set + cv_broadcast fired) but the OSv condvar waiter never woke = LOST OSv
## CONDVAR WAKE, proven (a ZFS hang would show zcw_done=0). BOTH send-side A/Bs REFUTED: OSV_WAKE_IPI_ALWAYS
## (drop the send_wakeup_ipi runqueue<=1 suppression) STILL wedges -> NOT the IPI guard; OSV_ZIL_FLUSH_INLINE
## STILL wedges -> NOT the taskq hop. So the wake is lost in the WAIT-MORPHING HANDOFF, BEFORE send_wakeup_ipi.
## THE MORPH PATH (read): condvar::wake_all -under _m.lock- -> _user_mutex->send_lock(wr) [morph: the cv
## waiter is handed to the ZCW mutex, woken only when the mutex is granted] -> either (a) count==0 uncontended
## -> wr->wake(), or (b) waitqueue.push(wr) + the RESPONSIBILITY HAND-OFF (RHO) lock-free protocol
## (handoff/CAS/pop-other-wake). wr->wake() -> thread::wake_impl waiting->waking CAS.
## CANDIDATE LOSS POINTS (steered): (1) the RHO race in send_lock(b) + the matching unlock() RHO - the
## classic lock-free hand-off drop where neither side commits to waking wr (heavy at VU64: many backends
## morph onto the same zcw mutex); (2) thread::wake_impl waiting->waking CAS no-op if the thread status
## raced; (3) the _user_mutex/zcw_lock morph-target validity.
## DECISIVE FAST A/B steered: OSV_CONDVAR_NO_MORPH=1 (wake the cv waiter DIRECTLY, skip send_lock morph).
## If the wedge DISAPPEARS -> lost wake is in the morph/RHO (candidate 1, fix the RHO or don't-morph here);
## if it STILL wedges -> the raw thread::wake_impl CAS (candidate 2). Splits morph-RHO vs wake-CAS cleanly.
## LIKELY a GENERAL OSv lfmutex/condvar RHO or wake-CAS lost-wakeup under high cross-vCPU contention - SAME
## CLASS as the raidz_reflow vre_cv bug in FINDINGS-osv-openzfs.md (check if that was ever root-caused - it
## may point straight at the RHO). If so, a huge general fix (any morphed cv-wake under contention). Bank
## bank/condvar-morph-wake-fix or bank/lfmutex-rho-fix depending on which candidate. Awaiting the NO_MORPH A/B.

## ESCALATION (agent bd33fb55): the lost wake is BELOW the ZIL/condvar layer - a SCHEDULER-WIDE cross-vCPU
## wake-to-halted-vCPU collapse under VU64. FIVE refutations all still wedge: FLUSH_INLINE, NO_MORPH,
## WAKE_IPI_ALWAYS x2 (unconditional IPI + incoming_wakeups_mask bypass), and the KILLER: ZIL_WAIT_TIMEOUT
## (a waiter self-rechecking zcw_done==1 via 1ms cv_timedwait_hires MUST proceed - so even the LOCAL TIMER
## wake is lost, not just cross-vCPU cv_broadcast). qemu~50% = ONE vCPU alive, rest halted-never-return.
## The ZIL WALWrite path is just where it first surfaces (global serialization point); zcw_done=1+asleep is
## the SYMPTOM of a deeper halt<->wake bug.
## GUARDRAIL (Linux control already rules out pure-substrate): Linux scales to VU64 ON THE SAME qemu 7.2
## -M pc host -> the host CAN wake halted vCPUs; OSv-specific state, real, not a qemu defect.
## DECISIVE A/B steered (fast, one env var): FORCE NO DEEP-HALT (huge OSV_IDLE_SPIN / no-halt build), re-run
## VU64. Wedge VANISHES -> HALT-ENTRY RACE (a wake enqueued in the window after the vCPU checks runqueue but
## before/at wait_for_interrupt with interrupts masked -> lost forever + explains the lost TIMER; fix = re-
## check incoming_wakeups + fence at halt entry). Wedge PERSISTS no-halt -> WAKE-ENQUEUE DROP (the wake
## never reaches incoming_wakeups/runqueue at all; thread::wake_impl CAS leaves thread not-queued, or the
## mask bit set-but-never-drained). Splits halt-entry-race vs wake-enqueue-drop. THEN gdb+qemu-s live vCPU
## state (RIP in wait_for_interrupt? RFLAGS.IF/LAPIC masked? queued work never picked up?) to confirm.
## THIS IS A FUNDAMENTAL OSv SCHEDULER lost-wakeup that caps ALL high-concurrency cross-vCPU-wake workloads
## (PG is the messenger). Naming it precisely (halt-entry-race vs wake-enqueue-drop + the exact race window/
## missing fence) IS the deliverable; the fix + VU64-wedge-gone A/B is the stretch. Bank bank/sched-halted-
## wake-fix. Deepest point the whole scaling arc has reached: from -PG slower on HammerDB- down to a vCPU
## halt<->wake race in the OSv scheduler.

## MAJOR CORRECTION (agent bd33fb55, measured, decisive): the VU64 wedge is an OOM PANIC, NOT a lost-wakeup
## deadlock. Console at the cliff: "Out of memory: could not reclaim any further. Current memory: 2868 Kb"
## (64G guest -> ~2.8MB in ~40s = ~1.5GB/s), backtrace in memory::reclaimer::do_reclaim, page-faults on all
## CPUs, NETWORK DOWN after (No route to host) = KERNEL PANIC. This EXPLAINS why all 6 wake-path A/Bs
## "failed" (all still OOM'd): the wake path was NEVER the bug. zcw_done=1+waiter-asleep was a SYMPTOM of
## the reclaim stall (waiter blocked while the reclaimer spins unable to free), NOT a lost condvar wake.
## => The whole scheduler/wake/morph-RHO/halt-entry line (which I steered toward) was chasing a SYMPTOM.
## The discriminator (the OOM console line) corrected it. Follow the data.
## THE REAL BUG: a FAST, concurrency-proportional OOM at VU64. NOT the known slow leak #2 (~0.85MB/backend,
## already fixed on this base) - that is ~280-round-slow; this is 40s-fast. A distinct fast-growth.
## CANDIDATES (distinguish via a per-5s per-pool sampler): ARC blowing PAST OSV_ZFS_ARC_MAX=32G under VU64
## write pressure (arc_c > 32G? evicting?); dirty-buffer/WAL/ZIL dirty-data accumulating faster than sync
## (OSv ZFS write-throttle / dirty-data-max backpressure not working?); fork-COW pages exploding across 64
## concurrent backend child ASes. Linux scales at VU64 same host (its reclaim/throttle handle it) = OSv bug.
## STEERED: measure the mem trajectory + which pool tracks the collapse (names the root); cross-check vs
## leak #2 (fast != slow); confirm VU-threshold (VU32 flat vs VU64 blows up = concurrency-proportional);
## fix at root (enforce ARC-max under pressure / wire the ZFS dirty-data write-throttle / free the per-
## backend growth). Bank bank/vu64-oom-fix. Naming the pool + trajectory = minimum deliverable.
## LESSON: a "lost-wakeup/deadlock" signature (everyone on a lock, zero IO, idle CPU) can be an OOM/reclaim
## STALL in disguise - the reclaimer holds/spins, waiters block, IO stops. CHECK free-mem + the console for
## OOM/panic BEFORE concluding "lost wakeup". zcw_done=1 alone was necessary-not-sufficient for a wake bug.

## POOL NAMED (measured, decisive): fork-COW ANONYMOUS memory across backend child ASes. MEMPROBE VU64:
## free_MB collapses 64GB->0.5GB while ARC stays 2GB (innocent, way under 32G cap) + dirty fixed 3.2GB
## (throttle OK). shared_buffers 16G + ARC 2 + dirty 3.2 ~= 21GB ACCOUNTED; ~42GB UNACCOUNTED = anon/
## fork-COW across 74 backend child ASes ~= 570MB/backend. RSS climbs with backend count (37->74) THEN
## keeps climbing write-driven -> OOM >64GB. Concurrency-proportional threshold VU32(~40 bk, ~44GB, fits)
## vs VU64(~74 bk, ~63GB, OOM). Linux scales (MAP_SHARED shared_buffers stays SHARED not per-child COW).
## NOT ARC (arc=8G cap still OOMs), NOT dirty, NOT lost-wakeup (reclaim-stall symptom). NOT the slow leak #2.
## THE DECISIVE A/B (running): shared_buffers 16G->2G. Settles BUG-vs-COST:
##  (a) BUG: OSv wrongly COW-DUPLICATES the MAP_SHARED|MAP_ANON shared_buffers per backend (should stay
##      shared). footprint drops ~with the sb delta. Concrete generic OSv fork MAP_SHARED-coherence bug.
##      commit 3364d5c68 (share writable MAP_SHARED 2MB pages across fork) is THIS area - a gap or a
##      re-COW path. Fix: keep anon-MAP_SHARED genuinely shared across fork children (shared PTs, no copy).
##  (b) COST: ~570MB/backend is genuine per-backend PRIVATE growth (relcache/catcache/work_mem/COW heap+
##      stacks+arena) - inherent OSv-fork per-backend footprint, harder fix, not a MAP_SHARED bug.
## Direct mechanism check steered: does shared_buffers VA take per-backend COW WRITE FAULTS / does a
## backend's PT of shared_buffers point at the SAME physical pages as the postmaster (shared/OK) or
## DIFFERENT (duplicated/bug)? Nails (a) vs (b) directly, not just by footprint inference.
## THIS IS THE REAL VU64 WALL: a fast concurrency-proportional fork-COW OOM. If (a), a clean high-value
## generic OSv fork fix that unwedges VU64+ (and may lift VU32 headroom). If (b), an inherent fork-model
## cost = a different conversation (reduce per-backend footprint, or accept a lower max-connections on OSv).
## Bank bank/vu64-oom-fix if (a) fixed. Agent to write RESULT.md + terminate after the sb=2G A/B.
