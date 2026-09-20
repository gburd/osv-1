# Benchmark methodology: benchmark the PROJECTED-MERGED FUTURE (operator directive 2026-09-13)

We file PRs upstream for things we expect to be merged. So the honest benchmark question is not "how
does the fix I am holding perform" but "how does OSv perform once all our work has landed". The
benchmark base must therefore be the **projected-merged future**: `upstream/master` + all our open PRs
we expect to land, composed together. This supersedes the ad-hoc "the fixes I was actively working on"
assembly that silently omitted #1502 and capped a sweep at VU32.

## What "projected-merged future" means precisely
Base = `upstream/master`
  + every OPEN, NON-DRAFT PR we author that is mergeable
  - DRAFT PRs (by definition not expected to merge as-is)
  - explicit DO-NOT-MERGE / tracking PRs (e.g. #1458)
  - superseded PRs (keep the successor, drop the predecessor)
  reducing each stacked/mutually-exclusive group to its intended head, conflicts resolved once.

This is both the right QUESTION (what does the merged world look like) and a complete GATE (you cannot
forget a fix, because the base IS the set of PRs).

## Two legitimate scopes, state which you used
1. **Full projected-merged base**: every eligible non-draft PR. The truest "future OSv" number. Larger
   conflict surface; some PRs (network: ipv6/RSS/MQ) do not affect a local-NVMe PG workload.
2. **Workload-scoped projected-merged base**: the subset of eligible PRs the workload actually exercises
   (for PG-on-ZFS: storage/sched/vfs/fork/mm/pagecache), composed clean. Network-only PRs omitted
   because they are not the workload under test and only add conflict surface, not signal.
Prefer (2) for a focused perf question and SAY it is workload-scoped; use (1) when the question is
"ship-readiness of the whole tree". Either way the base is DERIVED FROM THE PR LIST, not from memory.

## The gate stays, and gains a second form
- `.local/bench-base-gate.sh` (marker gate): fast, catches a missing REQUIRED fix by grep. Keep it as
  the pre-launch smoke check.
- `.local/build-projected-base.sh` (composition gate): constructs the base from the live PR list and
  reports exactly which PRs are IN, which are EXCLUDED (draft/dnm/superseded) and WHY, and which
  CONFLICT and need manual resolution. The base is only valid if every intended PR is either merged in
  or explicitly, visibly excluded with a reason. No silent omissions.

## Standing rule for every benchmark run and every benchmark agent brief
1. Build the base with build-projected-base.sh from the CURRENT PR list (not a remembered branch).
2. Run bench-base-gate.sh on the composed tree; refuse to launch if it fails.
3. Record in the run's identity block: the exact PR list composed IN, the list EXCLUDED with reasons,
   the base commit, and which scope (full vs workload-scoped) was used.
4. When a new eligible PR is filed, it enters the next base automatically because the base is derived
   from the PR list. When a PR merges upstream, it drops out of "ours to add" and appears in
   upstream/master - the composition script must dedupe against what master already contains.

## Why this is better than a fix checklist
A checklist is a second thing to maintain and can drift from the PR list. The PR list is the ground
truth of "what we expect to land". Deriving the base from it means the benchmark automatically tracks
our actual upstreaming state: nothing we intend to merge can be silently missing, and anything we do
NOT intend to merge (draft/dnm) is visibly excluded with a reason in the run record.

## Tooling built (2026-09-13)
- `.local/build-projected-base.sh [--scope full|pg] [--apply BR]`: derives the base from the LIVE PR
  list. Default IN for every non-draft, non-DNM PR; excludes only an explicit NUMBERED deny-list with a
  per-PR reason (a title-regex over-excluded - it dropped setlocale #1477 which PG calls - so exclusion
  is by number, auditable). Dry-run classifies + probes merge conflicts in a scratch worktree; --apply
  builds the branch, stopping if any PR conflicts so it is resolved once.
- `.local/bench-base-gate.sh <tree>`: fast pre-launch marker smoke check for the REQUIRED fixes.

## First classification (PG scope, 54 open PRs)
IN (35): #1438 #1439 #1440 #1441 #1449 #1450 #1456 #1461 #1464 #1465 #1472 #1477 #1478 #1479 #1480
  #1481 #1482 #1483 #1484 #1485 #1486 #1488 #1494 #1495 #1496 #1497 #1498 #1499 #1500 #1502 #1503 #1504
  #1505 #1506 #1507
EXCLUDED (19): 8 DRAFT (#1444 #1445 #1447 #1455 #1458 #1475 #1487 #1501), 1 DNM (#1458 also draft),
  10 deny-list (#1424 Crucible, #1442 IPv6, #1459 zfs-aarch64, #1463/#1467/#1470/#1471 network,
  #1490/#1491/#1493 aarch64, #1492 early-rng).

## Composition caveats to resolve when --apply is run for real
- #1456 (fork stage2 COW) is IN but interacts with the fork stack (#1455 draft base, #1475 draft
  nested). #1456 is the non-draft head; confirm it composes standalone on master or note the dependency.
- NUMA #1438 + #1441 are add/add against master (maintenance sweep flagged); the composition script's
  merge probe will surface the conflict and they get resolved once.
- #1502 + #1503: #1503 (per-chain) sits on top of #1502 (lock-order); include both since both are IN,
  order #1502 first.
- The merge probe in build-projected-base.sh reports each conflict; resolve in the scratch worktree,
  then --apply. This is the "resolve conflicts once" step, done ONCE per base refresh not per run.

## Net methodology change
The benchmark base is now DERIVED FROM THE LIVE PR LIST, not assembled from memory. A fix we intend to
merge cannot be silently missing (it is IN by default); a fix we do not intend to merge is visibly
excluded with a reason recorded in the run. The a2a-base-missing-#1502 class of error is now
structurally prevented.
  #1509 (virtio-blk per-queue completion) is a REQUIRED at-scale fix -> IN the projected base, and needs OSV_BLK_MQ_COMPLETE=1 set at boot
