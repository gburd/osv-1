# Banked wins blocked on a decision / waiting on a condition (2026-09-17)

## BLOCKED ON MAINTAINER (nyh offline - cannot self-merge/self-clear):
1. #1464 "sched: disperse threads faster in the load balancer" - APPROVED, waiting only on the maintainer
   to click merge. Zero action on our side.
2. #1439 "signal: implement signalfd(2)" - CHANGES_REQUESTED but STALE (all points answered through
   2026-09-08). Only nyh can clear the review flag. Do NOT nudge.
3. Merge ORDER when maintainer returns (all merge-clean, non-fork): #1464 (approved) + #1502/#1503/#1504,
   then #1488 (OpenZFS 2.4.4) + #1500 (lwext4 pin), then #1449 (security).
4. #1455/#1456 fork-stack COMPOSITION - a maintainer design decision (add/add vs increment). This is the
   KEYSTONE blocker: it gates both leak fixes (see below).

## BLOCKED ON THE FORK-STACK REACHING UPSTREAM (gated by #4 above):
5. LEAK #1 (fd/gfdt EMFILE fix) - REAL, 400-round-A/B-validated, review-ready on
   gh-fork bank/fork-fd-reap-leak-reviewready (build-validated). CANNOT open as a PR: its minimal base is
   the fork-arena + 3-commit shared-gfdt fd-table generation = 136 commits ahead of master, divergent from
   #1455/#1456 (they lack fork_arena.cc entirely; build-IMPOSSIBLE to stack). LANDS as one clean commit on
   whichever PR proposes the shared-gfdt fd-table generation. THE UNBLOCK: someone (maintainer decision)
   proposes the fork-arena + fd-table generation as its own PR. I can DRAFT that PR-proposal framing on
   request so leak #1 has a home ready to slot into.
6. LEAK #2 (fork-arena memory leak) - REAL FIX COMPLETE + 5-gate-validated (400 rounds/26,181 backends),
   banked gh-fork bank/fork-arena-real-reclaim (2 commits: 8 cross-AS-object identity-heap scopings [a
   generic fork-coherence fix, independently valuable] + the per-AS overflow reclaim). Bounded audit =
   provably complete. SUPERSEDES the grow-mitigation. Same fork-stack landing dependency as leak #1
   (gated on #4/#5). Pre-PR: strip the pre-existing leak_probe_stats() base cruft.

## WAITING ON A CONDITION (a validation or a re-measure) - actionable by us, not maintainer:
7. bank/fork-arena-grow-mitigation (3b3ab1ac4) - RETIRED: SUPERSEDED by the leak #2 real fix
   (bank/fork-arena-real-reclaim). It only delayed the OOM. Keep the branch as a historical fallback
   only; do NOT PR it.
8. #1510 (ext4 read-ahead) - DRAFT, waiting on ext4 re-measurement on current master to un-draft.
9. #1501 (OSV_IDLE_SPIN) - DRAFT; the HammerDB transfer verdict was overtaken by the M1 run-order-artifact
   reframe. Its isolate win is real; its M1-parity relevance is moot now. Decide: keep as an isolate-perf
   PR on its own merit, or close. (Leaning: keep - the recycle-latency deficit is a real, separate thing.)
10. Native-ZFS 4a - RETIRED (2026-09-17 sweep): SUPERSEDED by open PR #1478 (mergeable, merge-clean),
    which carries 4a's exact zfsdev_init change PLUS the 4 supporting pieces (RTLD_GLOBAL, /etc/mnttab,
    the before-pivot move, manifest+ZIL) that make it functional. Standalone 4a would be non-functional.
    Do NOT open; it lands via #1478 (maintainer-gated merge). Added #1478 to the maintainer merge queue.

## QUEUED CODE FOLLOW-UPS (actionable, not blocked, just not-yet-done):
11. Fold 4b RDSEED into #1492 (overlaps; do after #1492 review settles - do not open a competing PR).
12. Rebase the NUMA family (#1438/#1441/#1445) onto master's new SRAT/SLIT layer (substantive; when
    picking up the NUMA thread).

## THE ONE THING THAT UNBLOCKS THE MOST: getting the fork-arena + shared-gfdt fd-table generation PROPOSED
## as a PR (a maintainer composition decision). It unblocks BOTH leak fixes (the 2 biggest banked platform
## wins). Everything else is either a click-to-merge (maintainer) or a we-can-do-it validation.

## FORK-GENERATION UPSTREAM PROPOSAL (2026-09-17): drafted .local/FORK-GENERATION-UPSTREAM-PROPOSAL.md.
FINDING: the fork-arena + shared-gfdt fd-table generation is ~134 commits, STRICTLY STACKED on the
unmerged #1455/#1456. NOTHING in it can open as a mergeable PR until #1455/#1456 merge (filing now = a PR
against a nonexistent base). So the correct "draft it as a PR upstream" deliverable is a COMPOSITION
PROPOSAL (a decomposition into a landable S1..S8 series + where the 2 validated leak fixes slot in), for
the maintainer to accept/reshape - NOT a filed PR. #1458 (my own draft tracking PR) is the right home to
POST it. POSTED 2026-09-17 to #1458 (comment 5718101962) with operator approval - the composition ask + S1..S8
decomposition + the 2 validated leak fixes' landing points + the masking insight, waiting for the
maintainer to make the composition call.

## A2A RE-BENCHMARK DECISION (2026-09-17): YES, worth running - it is the OPEN MEASUREMENT.
We have NOT proven OSv-vs-Linux PG parity. We removed the known wedges/leaks (VU32 dentry, leak #1, leak
#2, 8 coherence bugs) + refuted the "OSv declines" curve as a run-order artifact, but the clean
fresh-boot-per-cell a2a on the projected-merged base is UNRUN, and the recycle-latency/wakeup deficit
(#4) HammerDB-transfer is unproven. The a2a run is EXACTLY the missing measurement. BUT a hard caveat:
the fixes live on the fork stack (bench/leakhunt lineage + bank/* branches), NOT on master. So the a2a
base must be the PROJECTED-MERGED-INCLUDING-FORK-STACK tree (the leakhunt lineage + both leak fixes +
the FILE/net_channel scopings), NOT upstream/master (which lacks all of it). Methodology (mandatory):
fresh-boot-per-cell (NOT the multi-cell-per-boot that manufactured the artifact), do NOT void the fresh
r1, hardened quiesce, OSv-vs-Linux on IDENTICAL m5d.metal + raw NVMe + matched 32GiB ARC + musl PG both,
io_uring AIO both, all levers on (WAKE_PULL, MQ-complete, IDLE_SPIN), p99 captured, VU8/16/32/64 each on
its OWN boot. This tests the REAL question: with the wedges/leaks gone + the artifact removed, does OSv
scale to parity, or does the recycle-latency deficit still cap it? Either result is honest + valuable.

## A2A CAPSTONE BENCHMARK LAUNCHED (2026-09-17, agent 2da3e1c8-4aee-475):
Base = gh-fork bank/fork-arena-real-reclaim (gate-PASS, both leak fixes + 8 coherence scopings + all 9
perf-fix markers). Methodology: fresh-boot-per-cell (NOT multi-cell-per-boot - the artifact lesson), do
NOT void fresh r1, hardened quiesce, OSv-vs-Linux on IDENTICAL m5d.metal + raw NVMe + matched 32GiB ARC +
musl PG + io_uring both, all levers, p99 captured, VU8/16/32/64 each own boot 3 reps. Tests: with wedges/
leaks gone + artifact removed, does OSv scale to PARITY, or does the recycle-latency/wakeup deficit cap
it? Either result honest. Results -> .local/a2a-final/. This is the OPEN MEASUREMENT that determines
whether the whole fix arc produced a parity-or-faster OSv/PG-on-ZFS solution.

## A2A-FINAL boxes (agent 2da3e1c8, for tidy-tracking): metal + driver, Owner=agent-a2afinal, lava
## us-east-2a. Agent confirmed it will terminate both + 0 orphans on any exit. Setup verified correct on
## all 3 corrected axes (raw NVMe passthrough, io_uring both, fresh-boot-per-cell). Running the OSv-vs-
## Linux fresh-boot curve VU8/16/32/64. Awaiting the measured curve + parity verdict.
