# POSSIBLE MAJOR MEASUREMENT-INTEGRITY REFRAME (2026-09-16): the M1 "decline" may be a run-order artifact.

## The trigger (agent ccc5615b, M1 verdict run)
The VU32 ~9,300 NOPM "collapse" was NOT a real decline. All 6 sweep cells ran on ONE guest boot;
throughput fell 169k -> 0 across sequential runs as the guest cumulatively degraded/wedged. With
FRESH-BOOT-PER-CELL + hardened quiesce, VU32 spin=10000 = 215,504 NOPM - healthy, HIGHER than VU16.
=> the tight ~9k triplet was a clean measurement of a DEGRADED state, not the baseline.

## Why this reaches BACKWARD to the whole M1 premise (the a2a matched run)
runcell.sh (the a2a harness) does NOT reboot between cells - it quiesces (2 CHECKPOINTs) then runs the
cell on the LIVE guest. Quiesce does NOT reset cumulative guest degradation (fragmentation / ARC state /
a slow wedge). So if the a2a run looped VU8->VU16->VU32 on one boot, its "decline" is a CONTAMINATION
SUSPECT - the same 169k->0 within-one-boot degradation.

## THE SMOKING-GUN PATTERN in the a2a data, reinterpreted
The a2a run VOIDED r1 as "cold-inflated" on EVERY arm and kept lower later reps:
  OSv VU8:  r1=158830 VOID -> r2/3/4 = 101898/104640/108688 (kept median 104640)
  Linux VU8: r1=158843 VOID -> 159792/161419/151307
  shape-fix VU32: r1=291357 VOID "cold" -> r2/r3 = 62044/62832 (kept ~62k)
THE REFRAME INVERTS THIS: r1 was NOT cold-inflated - it was the HEALTHY FRESH-BOOT run, and the later
reps were DEGRADED by run-order. The a2a agent VOIDED THE GOOD NUMBER and kept the contaminated ones.
  - OSv VU8 fresh ~158k (not 104k); shape-fix VU32 fresh ~291k (not 62k).
  - If so, OSv fresh-boot is FAR higher than the "declining" curve, and the M1 gap is MUCH smaller -
    possibly near parity (OSv VU32 fresh 215-291k vs Linux VU16 269k).
NOTE the Linux r1 was ALSO ~158k then settled ~159k (STABLE) - so Linux did NOT degrade run-order, only
OSv did. That asymmetry is itself the real OSv finding IF confirmed: OSv degrades across sequential
HammerDB cells on one boot where Linux does not - a cumulative-state/wedge bug, NOT a per-VU scaling wall.

## CAUTION - do NOT over-rotate (this must be PROVEN, it inverts months of conclusions)
1. Need the FRESH-BOOT curve: VU8/16/32/64 each on its OWN boot, 3 settled reps. Does OSv still decline
   fresh-boot, or scale/hold? (Agent running this.)
2. Confirm 215k VU32 replicates (3 fresh-boot reps) - one number is not enough after ~9k also looked clean.
3. The r1-was-healthy inversion is a HYPOTHESIS from the pattern - the agent must confirm a fresh boot
   reproduces r1-like numbers, not r2-like.
4. The ISOLATE gaps (OSv 1.5 vs Linux 13 lwbs, 3000 vs 7077 flush/s) were single continuous workloads,
   less run-order-sensitive -> likely STILL REAL. The isolate recycle-latency deficit and a HammerDB
   run-order-degradation bug can BOTH be true and are DIFFERENT problems.

## IF CONFIRMED, the honest correction is large and must be stated plainly:
The "OSv declines VU8->VU16->VU32 while Linux scales" headline - which drove the entire M1 investigation -
was substantially a HARNESS ARTIFACT (multi-cell-per-boot + voiding the healthy r1). The REAL OSv issues
are: (a) a per-commit recycle-latency deficit (isolate, real, OSV_IDLE_SPIN helps), and (b) a cumulative
guest degradation across sequential HammerDB cells that Linux does not have (a wedge/state bug, NOT a
scaling wall). The 9 fixes still stand on their own merit; the SHAPE narrative needs correction.
This would be the single most important correction of the campaign - measure it hard, report it straight.

## Standing methodology fix (regardless): FRESH BOOT PER CELL for HammerDB. Quiesce is NOT enough - it
## does not reset cumulative OSv guest degradation. Every future HammerDB sweep: one boot per cell, and
## do NOT void the first (fresh) run as "cold" - on OSv the fresh run may be the ONLY clean one.

## THE MECHANISM QUESTIONS (operator, 2026-09-16) - answered as far as MEASURED, rest steered:
Q1 WHY OSv degrades, Linux doesn't: NOT YET PROVEN. Decay shape 169k->43k->0->0->0->0 = progressive
WEDGE to HARD ZERO (not gradual) = a RESOURCE LEAK/EXHAUSTION accumulating across sequential HammerDB
cells (each churns 32-192 forked PG backends). Leading candidate: forked-backend teardown leaks
(threads/fd-table/fork-arena-COW-pages/dentries/condvars not reclaimed on disconnect) - OSv fork/COW is
young, Linux teardown mature. Fits OSv-only + reboot-fixes. Other candidates: L2-page-batch stuck at 0
(the earlier 26.9GiB-free wedge), dentry leak, ARC-reclaim-lag. The agent is instrumenting per-cell
thread/mem/fd/dentry/fork-arena counts + a thread-state histogram at the 0-NOPM point to NAME the leak.
Q2 WHY reboot fixes it: reboot resets ALL accumulated state (fresh AS, empty ARC/dentry cache, fresh
pools, zero leaked threads/fds). Reboot-fixes-it IS the signature of a leak/exhaustion class - if it were
per-VU scaling, VU32 would be slow FRESH too, but it is 215k fresh. So the reboot-dependence itself
proves it is accumulated-state, not a scaling wall.
Q3 Firecracker / bare metal: NO - all a2a + isolate runs were OSv-as-QEMU-KVM-guest. The FC A/B was an
OLD pre-fixes build (2026-08-18); NEVER true bare metal. So we do NOT know if the degradation is
OSv-internal (leak -> reproduces on FC + metal) or qemu/KVM-guest-state-specific. If the per-cell
instrumentation shows a clear guest-internal leak (thread/fd/dentry/fork-arena growing), it is
OSv-internal and substrate-independent. FC/metal confirmation is a separate follow-up.

## THE TARGET HAS SHIFTED (if confirmed): from "OSv throughput scaling" to "OSv forked-backend/
## connection-churn TEARDOWN LEAK". That is a concrete, generic, fixable OSv bug (helps any fork-heavy
## long-running workload, PG the forcing function) - and it is the REAL production question (a DB runs
## for weeks, churning connections; a per-boot wedge is a showstopper a reboot-per-cell benchmark hid).
## This is arguably a BIGGER and more valuable finding than the throughput parity number.
