# LANDMARK CORRECTION (2026-09-16): the M1 "OSv declines" story was substantially a run-order ARTIFACT.

## What changed (MEASURED, agent ccc5615b spinverdict run)
The entire M1 driving premise - "OSv throughput DECLINES VU8->VU16->VU32 while Linux SCALES" - was
substantially a run-order / cumulative-degradation HARNESS ARTIFACT, not a real OSv per-VU scaling wall.

EVIDENCE:
- Fresh-boot-per-cell VU32 (spin=10000, quiesced) = 215,504 NOPM: HEALTHY, ~2x VU16, NO collapse.
- The a2a run that established the decline ran ALL cells on ONE guest boot (runcell.sh never reboots;
  only 2 console logs, one served 3h22m with 109 "autovacuum worker took too long" wedge markers). It
  VOIDED the clean r1 (158k) as "cold-inflated" and KEPT the degraded r2-4 (~104k). The declining curve
  was manufactured by (a) multi-cell-per-boot contamination + (b) discarding the clean cell as "cold".
- Linux did NOT degrade (r1 158k -> stable ~159k); only OSv degraded within a boot.
- The ~9,300 "VU32 collapse" triplet was a clean measurement of a DEGRADED 4th-cell guest, not baseline.

## What the REAL bug is (the new target)
OSv PG-on-ZFS decays to a HARD-ZERO wedge across sustained forked-backend churn within one boot
(169k->43k->0->0->0->0), reboot-resettable = a progressive resource LEAK / teardown wedge in OSv's
fork/reap path. Generic, production-critical (a DB churns connections + autovacuums for weeks). Live
0-NOPM signature: 33/34 vCPUs SLEEPING (idle-WAITING, NOT idle-spin), 69 backends on LWLock:WALWrite=33
+ NULL-wait=32, + 109 autovacuum-worker-start-timeout markers. Leak-hunt agent b19ea12a is on it
(churn-loop repro -> per-round instrument -> name what grows -> fix -> validate flat).

## What STANDS (unaffected by the reframe)
- The 9-11 banked fixes: each a real generic G2 defect, none claimed as M1 parity. #1502 dentry
  (e2e proven), #1503, #1504 TCB, #1505 ZIL hires, #1506 ARC-max, #1507 fsync scan, #1508 physio,
  #1509 per-queue completion, #1472 wake-pull. All stand on their own merit.
- The ISOLATE finding (OSv per-commit recycle-latency deficit, 1.5 vs 13 lwbs in flight) - single
  continuous workload, not multi-cell-per-boot, so NOT the artifact. Real, independent. OSV_IDLE_SPIN
  helps the isolate. But it is a DIFFERENT problem from the wedge/leak.

## What is now VOID / corrected
- The "OSv declines VU8->VU16->VU32 while Linux scales" HEADLINE as a real scaling wall - it was
  substantially a harness artifact. The matched 104k->64k a2a curve is CONTAMINATED (multi-cell-per-boot
  + voided clean r1). Fresh-boot OSv VU32 = 215k, not 62k.
- Any conclusion that "the M1 gap is 1.5x at VU8 widening to Linux-scales" - contaminated. Fresh-boot
  gap is much smaller and needs a clean fresh-boot-per-cell OSv-vs-Linux curve to state honestly.
- The spin verdict is SECONDARY (run-order swamped it; at healthy 215k the guest is ~13% host CPU).

## STANDING METHODOLOGY FIX (permanent)
FRESH BOOT PER HAMMERDB CELL. Quiesce (checkpoint) is NOT enough - it does not reset the OSv wedge/leak.
Do NOT void the fresh r1 as "cold" - on OSv the fresh run is the CLEAN one; voiding it manufactured the
artifact. Every future HammerDB/pgbench sweep: one boot per cell, keep the fresh run.

## HONEST FRAMING for the record
This is the single most important correction of the campaign. Much of the "OSv is slower and declines"
narrative was contaminated by a benchmark harness that never rebooted + an agent that voided the healthy
cell. The real, more valuable finding is a concrete production-critical OSv fork/teardown wedge. The fixes
banked along the way are genuine improvements regardless. State this plainly; do not defend the old curve.
