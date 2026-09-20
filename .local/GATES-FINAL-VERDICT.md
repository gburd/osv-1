# Gates run FINAL verdict (2026-09-18, agent df2b1866) - the honest, corrected picture

## Account safety: both boxes TERMINATED (i-07cd70356cef08c3a metal, i-0d81859ea71589291 driver),
## 0 agent-gates orphans, 0 available volumes, SG /32-clean (no 0.0.0.0/0), solnix resources untouched.

## GATE 1 - idle-regression: PASS (decisive, host counter)
adaptive-v2 idle CPU 20.4/20.6% of one core vs fixed-10000 64.6/62.4%. Adaptive burns ~1/3 the idle CPU.
IDLE-SAFE -> promotable DEFAULT-ON. Real, clean, valuable.

## GATE 2 - VU32 + scaling (the CORRECTED reading):
OSv adaptive VU32 = 246458/229755/186862/180014 (median 208,309), ALL CPU-saturated, NO idle->wake
low-mode (the 0.5-vCPU waiting rep is GONE). Linux VU32 = 338,265; Linux VU64 = 486,112 (scales cleanly).
CORRECTION (do NOT overclaim): adaptive-idle-spin fixes the VU32 idle->wake TAIL/VARIANCE (removes the
intermittent low-mode), it does NOT lift the VU32 MEDIAN (a2a 205k -> gates 208k, FLAT). OSv VU32 is
STILL ~0.62x Linux at the MEDIAN. The idle->wake low-mode was never the median-capping factor; the
median gap is the SAME completion->waiter deficit that hard-deadlocks at VU64. So:
  - adaptive-idle-spin = REAL win on: (i) idle-safety (Gate 1), (ii) the VU32 idle->wake tail/variance.
  - adaptive-idle-spin does NOT: lift the VU32 median, close the VU32 parity gap, or touch VU64.
NOT claimed: "VU32 parity", "residual fixed". (The gates-run Linux VU32 rose 284k->338k vs the a2a -
same Ubuntu-glibc-ZFS-io_uring arm, so it is run-to-run Linux variance; the ratio worsened because Linux
rose, not because OSv fell. Either way OSv VU32 median is flat + behind.)

## VU64 - the NEW DOMINANT residual (fully characterized, see .local/VU64-WEDGE-FINDING.md):
Permanent, OSv-specific lost-wakeup DEADLOCK on the WAL-commit/ZIL-completion->waiter path. All 4
discriminators: (a) true deadlock never-recovers, (b) NOT io_uring-specific (worker wedges identically ->
ZFS-ZIL completion path), (c) NOT adaptive-caused (fixed wedges too -> pre-existing), (d) OSv-specific
(Linux scales to 486k, no wedge). adaptive-idle-spin cannot fix it (different layer: completion->waiter
vs idle->wake).

## THE WAKEUP DEFICIT HAS TWO FACES (the unifying insight):
1. idle->WAKE (an idle vCPU catching a wake in-spin) - the VU32 TAIL low-mode. adaptive-idle-spin FIXES
   this + is idle-safe. Ships as a standalone master PR (core/sched.cc, not fork-blocked).
2. completion->WAITER (a flush/commit completes but the waiter is never signaled) - the DOMINANT residual:
   it caps the OSv VU32 MEDIAN at ~0.62x Linux AND hard-deadlocks VU64. adaptive-idle-spin does NOT touch
   it. THIS is the next root-cause target - the ZIL/WAL sync-write completion -> condvar/waiter wakeup
   under high concurrency (bsd zil.c completion -> the OSv cv/wait_record wake path). Same cross-vCPU
   wakeup ROOT as the whole arc, at the completion->waiter layer.

## HONEST M1 PICTURE (measured): VU8/16 OSv FASTER (1.17x/1.29x); VU32 OSv ~0.62x Linux median (idle->wake
## tail fixed by adaptive-spin, median gap = completion->waiter deficit); VU64 OSv WEDGES (completion->
## waiter lost-wakeup deadlock, Linux scales). OSv leads at low concurrency; the completion->waiter wakeup
## deficit dominates from VU32 up and deadlocks at VU64. That path is the singular next target.

## NEXT ACTIONS:
- adaptive-idle-spin: DONE 2026-09-18. Rebased the adaptive change onto plain master as ONE self-contained
  commit (2be3701f0, G-signed, +113/-2, core/sched.cc + sched.hh, no fork/wake-pull/probe residue). Opened
  PR #1511 (cloudius-systems/osv:master, from gh-fork pr/sched-adaptive-idle-spin-master). Honest scope:
  idle-safe + idle->wake-tail fix, NOT a throughput-parity claim. SUPERSEDES #1501 (closed as superseded,
  the adaptive window subsumes the fixed knob via OSV_IDLE_SPIN_ADAPTIVE=0). THE FIRST scaling-arc fix to
  reach upstream DIRECTLY (not fork-blocked). Awaiting maintainer review.
- VU64/completion->waiter: a dedicated root-cause run (needs EC2) - localize where the ZIL/WAL flush
  completion fails to signal the waiter under concurrency.
