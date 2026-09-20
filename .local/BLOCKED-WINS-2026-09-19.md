# Blocked / waiting wins - snapshot 2026-09-19 (after the footprint fix + env audit)

## BLOCKED ON MAINTAINER - CORRECTED: the MERGER is @wkozaczuk, last merge 2026-08-17 (#1473), silent ~34
## days. (I had been tracking nyh's 08-03 date - the wrong person. And 0e34e4dc2 is MY OWN commit from
## #1423 which wkozaczuk merged that same day - which is exactly why master stopped there.)
- #1464 "sched: disperse threads faster in the load balancer" - APPROVED, waiting only on a merge click.
- #1439 "signal: implement signalfd(2)" - CHANGES_REQUESTED but STALE (all 8 threads answered). Only the
  maintainer clears it. Not nudging.
- Merge queue when they return: #1464 (approved) + #1502/#1503/#1504, then #1488 (OpenZFS 2.4.4) + #1500
  (lwext4 pin), then #1478 (native-ZFS runtime pool) + #1449 (security).
- #1511 (adaptive idle-spin) - OPEN, 0 comments/0 reviews, awaiting FIRST review. Direct-to-master, clean.
- #1512 (NEW, opened 2026-09-20) - bench: the durable-write syncwrite isolate. Parent IS upstream/master
  (pure fast-forward), 1 file, no kernel/build change, G-signed. Opened because it is the INSTRUMENT behind
  #1511's published table - without it in-tree a reviewer cannot reproduce #1511's numbers. Makes #1511's
  evidence checkable rather than asserted.
- #1464 VERIFIED one-click: reviewDecision=APPROVED, mergeStateStatus=CLEAN, mergeable=MERGEABLE.

## THE KEYSTONE DECISION (gates the three biggest banked fixes)
- #1455/#1456 fork-stack COMPOSITION. I posted the S1..S8 decomposition proposal to #1458 (comment
  5718101962) on 2026-09-17. STILL NO REPLY. Until that lands, NOTHING in the fork generation can open as
  a mergeable PR (strictly stacked on the unmerged #1455/#1456).

## THREE BIG WINS - DONE + VALIDATED, blocked ONLY on the keystone above
1. LEAK #1 (fd/gfdt EMFILE) - 400-round A/B validated. Review-ready: bank/fork-fd-reap-leak-reviewready.
   Lands as S5.
2. LEAK #2 (fork-arena memory) - 5-gate validated (400 rounds / 26,181 backends) + 8 cross-AS coherence
   scopings. bank/fork-arena-real-reclaim. Lands as S8.
3. FOOTPRINT FIX (NEW, the practical unblocker) - per-backend private 247MB -> 10.0MB (24.7x, inside
   Linux's 5-15MB band); MAX BACKENDS ~74 -> 576, stopped by max_connections=600 with 42.4GB STILL FREE so
   576 is a FLOOR. bank/fork-footprint-reduction-signed @ 1480fbee1 (all 5 commits G-signed, tree
   byte-identical to the validated branch). Lands with the fork series (S8 area).
   PRE-PR TODO (documented, needs a build check): strip the probe-only bits (g_ovf_recycled,
   overflow_stats(), the probe comment blocks, and the pre-existing leak_probe_stats cruft). KEEP
   ovf_mapped - it LOOKS like a probe counter but is the fix's per-AS window CURSOR (load-bearing).

## UPSTREAM, NOT FORK-BLOCKED (the scaling arc's directly-shippable yield - 5 scheduler PRs)
#1511 (adaptive idle-spin, supersedes #1501) | #1484 (skip null-thread wake) | #1480 (condvar lock before
checking the wait queue) | #1472 (idle-CPU pull work-stealing) | #1464 (load-balancer disperse, APPROVED).

## OUR-COURT, CONDITION-GATED
- #3 SCALING RE-TEST (VU32/64/128/192 with the footprint fix) + #4 the VU32 distinct factor: IN FLIGHT
  (agent ab2f349c, boxes i-0295dadedf57f4f0c + i-00b52ea02ffc05430). This is the real "does OSv scale like
  Linux" answer now that hundreds of backends are possible.
- #1510 (ext4 read-ahead) - DRAFT, waiting on an ext4 re-measure on current master (needs EC2).
- The footprint probe/fix SPLIT - deferred to PR time WITH a compile check (I cannot build locally).
- bank/fork-arena-grow-mitigation - RETIRED (superseded by the real reclaim fix).

## QUEUED CODE FOLLOW-UPS (not blocked, just not yet done)
- Fold 4b RDSEED into #1492 (after #1492's review settles; do not open a competing PR).
- Rebase the NUMA family (#1438/#1441/#1445) onto master's SRAT/SLIT layer.
- The BEFORE-arm stack-overflow-at-high-backends signature the footprint run saw (29GB free, NOT the OOM)
  - possibly a SEPARATE bug worth a look.

## NOT STARTED
- M2/PGXN (every PGXN extension identical OSv-vs-Linux; pg_stat_statements, pgvector, PostGIS). The next
  milestone. Exercises the dlopen/ELF path the fork/COW fixes repaired.

## CLOSED / CORRECTED THIS ROUND (so it is not re-litigated)
- The VU64 wall: SOLVED. It was the footprint churn bug (overflow commit = 99% of per-backend memory), NOT
  a lost-wakeup/scheduler bug - six wake-path A/Bs plus the OOM console refuted that line.
- The env/getenv scare: CLEARED. putenv DOES run (the missing log line is a verbose-gated debugf). Only
  consumers latching before parse_options (loader.cc:818) are affected - fork_arena::init was the one real
  case. No campaign result invalidated. Bonus correction: OSV_ZFS_ARC_MAX was absent from the a2a base, so
  OSv ran a ~2GB ARC vs Linux's matched cap => the a2a ratios are CONSERVATIVE for OSv, not inflated.
- The VU32 gap is NOT memory pressure (ruled out with a mechanism: ovflive_MB=0 in both arms at 32 clients).

## DECISIONS / CONDITIONS FOR THE OPERATOR
1. The #1458 keystone is the single highest-leverage unblock - three validated fixes wait on it. Nothing I
   can force while the maintainer is offline.
2. After the scaling re-test lands: if OSv now scales VU64-192, the M1 story is complete and M2/PGXN is the
   natural next milestone. If a new wall appears, it gets named and chased like the others.

## SWEEP 2026-09-19/20 (agent 903daebc) - externally NOTHING moved; internally 3 actions taken:
- KEY CORRECTION: the merger is @wkozaczuk (last merge 2026-08-17, #1473), not nyh-since-08-03. master
  stopped at 0e34e4dc2 because that IS the commit he merged that day (my #1423). ~34 days silent.
- 0 new reviewer comments repo-wide; #1458's S1..S8 proposal has 0 replies AND 0 reactions; #1511 has 0
  reviews; #1439 still stale (8/8 threads answered); lwext4 #100 byte-identical on its 8th check.
- Deps all current (OpenZFS 2.4.4 correctly prepared in #1488 - gitlink 71a9f957 = peeled tag AND
  .gitmodules branch; lwext4 pinned in #1500; apps/kbuild/acpica/swagger-ui/osv-gui current). Bumped nothing.
- 48 clean / 8 conflicting PRs - identical set (upstream unmoved, so no new conflicts).
- #1474's two review asks VERIFIED already on master - nothing owed there.
- ACTIONS I TOOK: (1) opened #1512 (the syncwrite bench instrument, for #1511 reproducibility - the agent
  drafted-and-held it on "maintainer taste"; I judged reproducibility of an in-review PR to outweigh queue
  noise); (2) removed 3 VERIFIED-SPENT worktrees (close-range + numa content confirmed blob-identical on
  master; scrub-aarch64 content confirmed carried in open #1459) - 14 -> 11 worktrees, ~80MB reclaimed
  (submodule-bearing trees needed `submodule deinit` then a plain rm + `worktree prune`); (3) the agent
  fixed #1511's body ("#1501 will be closed" -> "is now closed") and deleted 3 provably-dead /tmp entries.
- EC2: 0 orphans. The live agent-scale boxes (i-00b52ea02ffc05430 metal + i-0295dadedf57f4f0c c5.9xlarge
  driver) were correctly left untouched by the sweep.
