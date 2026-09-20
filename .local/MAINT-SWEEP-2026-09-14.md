# Maintenance sweep 2026-09-14 (agent 11dee939, parallel to M1-confirm 0c90e588)

## What CHANGED since the 2026-09-13 sweep (agent bc56ff97)
- **Open PRs 54 -> 56.** Two new master-facing PRs filed this session: **#1508** (vfs physio
  per-iovec, extracted from #1424) and **#1509** (virtio-blk per-queue completion). Both OPEN,
  both merge-tree CLEAN vs 0e34e4dc2, no reviews yet.
- **Mergeability 45/9 -> 47/9.** The +2 clean is exactly #1508/#1509; the 9 conflicts are the
  SAME 9 as before (#1438 #1440 #1441 #1445 #1447 #1449 #1456 #1458 #1475). No new bit-rot.
- Everything else identical to the prior sweep.

## Task-by-task (all verified fresh, evidence in report)
1. **Reviews: 0 unanswered human comments across all 56.** Only 6 PRs have ANY human touch
   (#1439 #1447 #1455 #1461 #1463 #1464); gburd's reply is last after every nyh/wkozaczuk comment.
   #1464 APPROVED (nyh 2026-08-03). #1439 CHANGES_REQUESTED is STALE (all points answered thru
   2026-09-08, never re-reviewed). No NEW human comment since 2026-09-13. Nothing to post.
2. **New PRs clean:** #1508 #1509 #1472 #1502 #1505 #1507 all OPEN + merge-tree CLEAN + no review.
3. **Drafts:** #1444 CLEAN, #1455 CLEAN, #1487 CLEAN, #1501 CLEAN; #1445/#1447/#1458/#1475 CONFLICT
   (numa add/add, ext4, tracking-PR, fork add/add). #1447: head pr/ext4-perf (06210dfc) CONFLICTS;
   **pr/ext4-perf-v2 (8f95be01) exists on gh-fork + local, is merge-tree CLEAN, includes af27ba4b7.**
   PR head cannot be repointed via API -> FLAGGED for operator to retarget or reopen.
4. **Deps all current, 0 bumps:** OpenZFS #1488 pins 71a9f957 == zfs-2.4.4 tag (newest stable;
   2.4.99 is dev). lwext4 #1500 pins 6f6d8f7c == osvunikernel/lwext4 master tip (2025-07-04);
   gkostka dormant (code tip 2022-09-22, last push 2024-03-22). musl v1.2.1 (2020) deliberate.
   acpica 3e45e0f2 (2013) OOS.
5. **Upstream elsewhere: no new activity.** gkostka/lwext4#100 OPEN 0 comments (unchanged since
   2026-07-14). osv-apps #71 idle. osv-apps #73 draft, 2 comments both gburd, no reviewer.
6. **Remaining work: unchanged from prior sweep + M1-confirm now IN FLIGHT (do not touch).**
7. **Sync: upstream == gh-fork == origin master == 0e34e4dc2, unmoved since 2026-08-17.** No ff.
8. **Nothing ready-but-unfiled.** #1507/#1508/#1509 already absorbed the session's ready work.
9. **/tmp: removed ~68K of clearly-OSv scratch** (10 body-14xx.md drafts, 1494/1497 md, oz*.sh,
   blk.log, mergetree/mt txt, empty osv-steer-wt tree). LEFT all other-project files (xtc/xbench
   .ndb dirs xb-fix 1.7G / xb2-fix 1.5G / dp-fix 187M, xtc livelock-fix 1.1G + pgdata_*fix, libdb
   159-combined.patch, pgfts 159_am.diff, amgettuple am_*.c, vector 1m_findings.md). Worktrees
   14->14 all load-bearing (3 sole-anchor detached: forksym/xastest/scrub-aarch64 = 0 refs;
   6 live branches ahead of master; rest back open PRs). No root-owned OSv build trees.
10. **EC2: 0 ours-orphans.** 2 live agent-m1confirm boxes (i-016b92.../i-01dabe..., relaunched
    15:27 today, re-tagged from a2abench7) LEFT per operator steering. fts + solnix boxes NOT ours.
    vol-0d12161abd705bd1b (20G, 2026-09-11) still unattributable -> left, noted. solnix volumes
    (Owner=gregburd) not ours.

## Operator steering received mid-sweep
The two boxes tagged agent-a2abench7 at first glance were the LIVE M1-confirm run with a reused
script that hardcoded the wrong tag; the other agent re-tagged them to agent-m1confirm. Confirmed
by LaunchTime (minutes old, not days). Rule applied: only reap agent-* that are OLD AND confirmed
done; when in doubt leave + report. No terminations performed.
