# Blocked / waiting wins - snapshot 2026-09-20

## BLOCKED ON THE MAINTAINER (@wkozaczuk, last merge 2026-08-17 / ~34 days silent - I cannot self-merge)
- #1464 "sched: disperse threads faster in the load balancer" - APPROVED + mergeStateStatus CLEAN +
  MERGEABLE = literally one click. Verified.
- #1439 "signal: implement signalfd(2)" - CHANGES_REQUESTED but STALE (all 8 threads answered, lastBy=gburd).
  Only the maintainer clears a review flag. Not nudging.
- #1511 (adaptive idle-spin) + #1512 (syncwrite bench) - both OPEN, 0 comments, 0 reviews. Awaiting FIRST
  review. Both direct-to-master and merge-clean.
- Merge queue behind those: #1502/#1503/#1504, then #1488 (OpenZFS 2.4.4) + #1500 (lwext4 pin), then
  #1478 (native-ZFS runtime pool) + #1449 (security).

## THE KEYSTONE (gates the THREE biggest banked fixes)
#1455/#1456 fork-stack COMPOSITION. My S1..S8 decomposition proposal is on #1458 (comment 5718101962,
posted 09-17) - STILL no reply, no reactions. A second #1458 comment (5749965679, posted 09-20) adds the
footprint fix + the scaling verdict in generic terms. Until the composition is decided, nothing in the fork
generation can open as a mergeable PR (it is strictly stacked on the unmerged #1455/#1456).

## THREE BIG WINS - DONE + VALIDATED, blocked ONLY on that keystone
1. LEAK #1 (fd/gfdt EMFILE) - 400-round A/B. bank/fork-fd-reap-leak-reviewready. Lands as S5.
2. LEAK #2 (fork-arena memory) + 8 cross-AS coherence scopings - 5-gate validated (26,181 backends).
   bank/fork-arena-real-reclaim. Lands as S8.
3. FOOTPRINT FIX - VALIDATED END-TO-END under real load: per-backend private 247MB -> 9.4-12.5MB and FLAT
   from 42 to 202 address spaces; 576 concurrent backends with 42.4GB still free (a floor, not a ceiling);
   1.43TB of churn recycled out of 1.66GB live. bank/fork-footprint-reduction-signed @ 1480fbee1 (5 commits,
   all G-signed). PRE-PR TODO: strip the probe-only bits WITH a build check - and KEEP ovf_mapped, which
   looks like a probe counter but is the fix's per-AS window CURSOR (load-bearing).

## UPSTREAM AND NOT FORK-BLOCKED (the scaling arc's shippable yield - 6 PRs)
#1511 adaptive idle-spin | #1512 syncwrite bench (makes #1511's table reproducible) | #1464 load-balancer
disperse (APPROVED) | #1472 idle-CPU pull work-stealing | #1480 condvar lock-before-waitqueue | #1484
null-thread wake.

## THE ANALYTICAL RECORD IS NOW DURABLE (was a single-host risk)
notes/pg-campaign-record @ 1398cc43e on BOTH origin (private) and gh-fork - 1568 files, G-signed, every
verdict AND every refuted hypothesis retracted in place, plus the harness scripts and the methodology rules.
The sweep is refreshing it with the ~78 newer .local changes.

## OUR COURT, IN FLIGHT
- The ASYNC WRITE-COMPLETION bottleneck + the AioUringCompletion LIVENESS WEDGE (3/11 high-VU cells):
  root-cause run live now (agent 2b47fd10). This is the last named limit on PG scaling.
- #1510 (ext4 read-ahead) - DRAFT, needs an ext4 re-measure on current master (EC2).
- The footprint probe/fix split - deferred to PR time WITH a compile check.

## QUEUED, NOT BLOCKED
- Fold 4b RDSEED into #1492 (after #1492's review settles).
- Rebase the NUMA family (#1438/#1441/#1445) onto master's SRAT/SLIT layer.
- The BEFORE-arm stack-overflow-at-high-backends signature (29GB free, not the OOM) - possibly a separate bug.

## NOT STARTED
- M2/PGXN (every PGXN extension identical OSv-vs-Linux). The next milestone after the write-completion work.

## SETTLED THIS ROUND (do not re-litigate)
- The VU64 wall was the footprint churn bug, NOT a lost wakeup (6 wake A/Bs + the OOM console refuted it).
- The env/getenv scare is CLEARED: putenv runs; only pre-parse_options consumers are affected. No campaign
  result invalidated. And OSv ran a ~2GB ARC vs Linux's matched cap in the a2a, so those ratios are
  CONSERVATIVE for OSv.
- "OSv cannot use its RAM" (MY claim) is REFUTED: 2047MB is the idle floor; under load arc_c reached
  28,748MB. My proposed 2GiB Linux cap would have handicapped Linux and inflated OSv - the agent caught it.
- The VU32 gap is NOT the ZIL/commit path: dropping durability WIDENED it (0.49x -> 0.063x).

## FOR THE OPERATOR
1. The #1458 keystone remains the single highest-leverage unblock - three validated fixes wait on it, and
   nothing can force it while the maintainer is silent.
2. #1464 is one click whenever they return.
3. After the write-completion root-cause lands: either a generic io_uring/ZFS/pagecache fix (and a re-test),
   or M2/PGXN as the next milestone.
