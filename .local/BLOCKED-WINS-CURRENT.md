# Blocked / waiting wins - current snapshot (2026-09-17b)

> CORRECTION (2026-10-26 maintenance sweep): the "nyh offline since 2026-08-03" claim below is
> STALE and WRONG. @nyh commented on #1508 on 2026-10-20 and reviewed the locale series on
> 2026-10-15; he is active DAILY (on scylladb/scylladb), just intermittent on OSv. #1464 was
> APPROVED by @nyh (not @wkozaczuk). The fork benchmark is blocked by the OPERATOR'S
> cleaner-provenance decision (2026-10-24), not by a dead maintainer. Current status lives in
> .local/maint/RESULT.md; prefer it over the snapshot below.

> UPDATE (2026-10-31 maintenance sweep): the fork-UAF dynamic-TLS fix LANDED as `1bd962e7d`
> ('sched: keep dynamic TLS on the identity heap for fork children', G-signed). PR #15 DRAFT on
> gburd/osv-1 (branch pr/fork-setup-tls-identity-heap). integ/pg-master AND integ/pg-fork-zfs
> (=#1458 head) both FF'd to 1bd962e7d. aarch64 fork port COMPLETE (concfork 10/10 fault -> 0/10,
> invariant positively proven off-arena). Three of our PRs also landed on master directly since
> the last sweep: #1521 (>64 CPUs, now master tip 28c0f5a4b), #1508 (physio deletion, e0cedeca0),
> #1526 (random harvest flush, 872f606b7).
>
> NEW FOLLOW-UP FINDING (NOT a blocker): **x86 fork-child residual ~20% fault.** With the fix,
> x86 tst-fork-concfork still shows ~3/15 faults at a SEPARATE pre-existing fork-child USER-stack
> teardown face (fault at a user VA ~0x2000.., e.g. RSP in mutex::lock()), present with AND without
> the fix (so the fix is 0-regression on x86, not the cause). aarch64 is driven to 0/N; x86 has an
> ADDITIONAL arena/teardown site this fix does not close.
>   - Waiting for: an operator DECISION to pursue it.
>   - Needed if: an x86 fork-heavy workload is planned (aarch64 is the target ISA; x86 is a
>     no-regression cross-check, so x86-reaching-0/N is not required for the aarch64 port).
>   - How you'd know it cleared: a follow-up identity-heap/teardown fix for the user-stack face
>     drives x86 concfork to 0/N, byte-identical to the aarch64 result.

## BLOCKED ON MAINTAINER (nyh offline; I cannot self-merge/self-clear):
- #1464 "sched: disperse threads faster" - APPROVED, waiting only on a merge click.
- #1439 "signalfd(2)" - CHANGES_REQUESTED but STALE (all points answered); only the maintainer clears it.
- Merge queue when they return (all clean, non-fork): #1464 + #1502/#1503/#1504, then #1488 (OpenZFS 2.4.4)
  + #1500 (lwext4 pin), then #1478 (native-ZFS runtime pool) + #1449 (security).

## THE KEYSTONE DECISION (unblocks the two biggest platform wins):
- #1455/#1456 fork-stack COMPOSITION. I POSTED the composition proposal to #1458 (2026-09-17, comment
  5718101962): the ~134-commit fork-arena + shared-gfdt fd-table generation decomposed into an S1..S8
  series, with the two validated leak fixes landing in S5/S8. AWAITING the maintainer's composition call.
  Until then NOTHING in the fork generation can open as a mergeable PR (strictly stacked on unmerged
  #1455/#1456).

## THE TWO BIGGEST WINS - DONE ENGINEERING-WISE, blocked only on the keystone above:
- LEAK #1 (fd/gfdt EMFILE) - real, 400-round-A/B-validated, review-ready (bank/fork-fd-reap-leak-reviewready).
  Lands as S5's natural commit.
- LEAK #2 (fork-arena memory) - real, 5-gate-validated (400 rounds/26,181 backends), banked
  (bank/fork-arena-real-reclaim, 2 commits: 8 cross-AS coherence scopings + the per-AS overflow reclaim).
  Lands as S8's natural commit. SUPERSEDES the grow-mitigation (retired).
- Pre-PR cleanup for both: strip the pre-existing leak_probe_stats() base cruft (0 callers) at PR time.

## OUR-COURT, CONDITION-GATED (actionable by us, not maintainer):
- a2a capstone benchmark - COMPLETE (2026-09-17). VERDICT: OSv SCALES (shape flipped declining->scaling),
  FASTER than Linux at VU8 (1.17x) + VU16 (1.29x), trails at VU32 median (0.72x) due to an intermittent
  OSv-specific cross-vCPU WAKEUP-LATENCY low-mode (proven via qemu-cpu discriminator; no Linux analog).
  Boxes terminated, 0 orphans. Full: .local/A2A-FINAL-VERDICT.md + .local/a2a-final/RESULT.md. The named
  residual = OSv wakeup latency (the #1501/OSV_IDLE_SPIN lever + broader scheduler work) = the next target.
- #1510 (ext4 read-ahead) - DRAFT, waiting on an ext4 re-measure on current master.
- #1501 (OSV_IDLE_SPIN) - RESOLVED (2026-09-17): KEPT + UN-DRAFTED (ready for review). It is a GENERAL OSv
  scheduler improvement (env-tunable idle spin-before-halt in cpu::do_idle(); avoids the halt/wake VM-exit
  round-trip for ANY cross-vCPU-wakeup workload, not just PG), merge-clean on master, default-unchanged
  (opt-in), honestly framed (host-conditional, no M1/parity claim - the body already correct). The draft
  status was only the now-moot M1-transfer question. Now awaiting maintainer review like any master PR.
- bank/fork-arena-grow-mitigation - RETIRED (superseded by leak #2 real fix); historical fallback only.

## QUEUED CODE FOLLOW-UPS (not blocked, just not-yet-done):
- Fold 4b RDSEED into #1492 (after #1492 review settles; do not open a competing PR).
- Rebase the NUMA family (#1438/#1441/#1445) onto master's SRAT/SLIT layer (when picking up NUMA).

## NOT STARTED:
- M2/PGXN (every PGXN extension identical OSv-vs-Linux; pg_stat_statements, pgvector, PostGIS) - the next
  major phase after M1. Exercises the dlopen/ELF path the fork/COW fixes repaired.

## DECISIONS I NEED FROM YOU:
1. RESOLVED: #1501 kept + un-drafted (general OSv scheduler improvement, ready for review).
2. After the a2a result: if parity -> the arc is proven, move to M2/PGXN? If still-behind -> chase the
   named residual (recycle-latency/wakeup deficit) as the next scaling target?

## SWEEP 2026-09-17b CONFIRMATION (agent d3e13776): zero material change, nothing actionable.
0 new reviewer comments; NO maintainer reply to the #1458 composition proposal (comment 5718101962) -
maintainer offline since 2026-08-03. Deps stable (OpenZFS 2.4.3/2.4.4-in-#1488, lwext4 #1500), unmoved
upstream 0e34e4dc2, same 8 conflicting PRs, osv-apps 3f93f43 current, 0 EC2 orphans, 0 orphan volumes.
Nothing openable (fork-stack blocked; 4a superseded by #1478). PROGRAM STATE = clean holding: everything
actionable is done or in-flight (the a2a capstone), the rest is maintainer-gated. Report:
.local/maint-2026-09-17b-sweep.md.
