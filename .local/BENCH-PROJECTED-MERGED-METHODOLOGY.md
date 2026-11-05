# Benchmark methodology: benchmark the PROJECTED-MERGED FUTURE (operator directive 2026-09-13)

We file PRs upstream for things we expect to be merged. So the honest benchmark question is not "how
does the fix I am holding perform" but "how does OSv perform once all our work has landed". The
benchmark base must therefore be the **projected-merged future**: `upstream/master` + all our open PRs
we expect to land, composed together. This supersedes the ad-hoc "the fixes I was actively working on"
assembly that silently omitted #1502 and capped a sweep at VU32.

## What "projected-merged future" means precisely
Base = `upstream/master`
  + every open PR (any author) whose reviewed manifest row is INCLUDE, merged in row order
  + each reviewed ALTERNATIVE(<sha>) commit, at its row's position
  Every other open PR also has a row: EXCLUDE(reason), ALTERNATIVE(#M) (covered by INCLUDE row #M) or
  BLOCKED(clearance). Draft state is metadata, not a disposition. A do-not-merge or tracking PR (#1458,
  or a title or label saying do-not-merge or DNM) is EXCLUDE or BLOCKED only. A superseded predecessor
  is EXCLUDE(reason) or ALTERNATIVE(#successor). A stacked child must not carry an excluded parent's
  head (FAIL[excluded-ancestor]). That check is ancestry only, so it misses a rebased or cherry-picked copy.

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

## The gates
- `.local/build-projected-base.sh --manifest FILE [--prs-json P --prs-total T] [--base REF]
  [--remote NAME] [--out NEWDIR] [--plan-only]` plans the base from a reviewed manifest (one row per
  open PR). Plan-only is the default, and it writes nothing to the repository. After a clean plan,
  `... --apply NEW-BRANCH --worktree NEW-PATH` builds the base in a new branch and worktree. A conflict,
  a fetch failure, a moved head or an excluded ancestor fails. BLOCKED rows give exit 3.
- `.local/bench-preflight.sh` is the only launch gate (usage in AGENTS.md). Its tree is the --apply
  worktree, with nothing on top.
- `.local/bench-base-gate.sh` is a marker smoke test and NEVER a launch gate. It is fail-open on
  ancestry and honours BENCH_ALLOW_STALE_BASE.

## Standing rule for every benchmark run and every benchmark agent brief
1. Freeze a PR snapshot, write and review the manifest (one row per open PR), and plan with
   build-projected-base.sh. A new PR without a row fails the plan (FAIL[missing]), so it cannot be forgotten.
2. --apply into a NEW branch and worktree. Commit nothing on top: a host-only patch is a PR with an
   INCLUDE row, or a reviewed ALTERNATIVE(<sha>) commit.
3. Build from that worktree, run bench-preflight.sh on it, and launch only on exit 0.
4. Record in the run's identity block: the manifest and its sha256, the plan's FINAL tree, the base
   commit, the levers file's sha256, and the scope (full vs workload-scoped). A PR that merges upstream
   leaves the snapshot. Delete its row, or the plan fails (FAIL[unknown]).

## Why this is better than a fix checklist
A checklist is a second thing to maintain and can drift from the PR list. The PR list is the ground
truth of "what we expect to land". Deriving the base from it means the benchmark automatically tracks
our actual upstreaming state: nothing we intend to merge can be silently missing, and anything we do
NOT intend to merge (draft/dnm) is visibly excluded with a reason in the run record.

## Tooling built (2026-09-13)
(HISTORICAL, superseded 2026-10 by the manifest composer above: --scope, the deny-list and IN-by-default
are gone, and bench-base-gate.sh is no longer a gate.)
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
- A conflict is FAIL[conflict] with a merge-tree receipt, and --apply refuses it. Resolve it once per
  base refresh, as a reviewed ALTERNATIVE(<sha>) commit on the conflicting row, then re-plan.

## Net methodology change
The benchmark base is now DERIVED FROM THE LIVE PR LIST, not assembled from memory. A fix we intend to
merge cannot be silently missing (every open PR needs a reviewed row); a fix we do not intend to merge is visibly
excluded with a reason recorded in the run. The a2a-base-missing-#1502 class of error is now
structurally prevented.
  #1509 (virtio-blk per-queue completion) is a REQUIRED at-scale fix -> IN the projected base, and needs OSV_BLK_MQ_COMPLETE=1 set at boot
