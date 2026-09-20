# Blocked / waiting wins - snapshot 2026-09-18 (lava-expiry context)

## URGENT - lava account expires in a few hours:
- Live box i-016e19e060a57409f (agent-wakelat, adaptive-idle-spin fix) racing the expiry. Steered to push
  the fix code EARLY + do the fast isolate A/B before the slow a2a re-run + self-terminate with margin.
  If lava dies mid-run: box orphans (no cost, billing stops with account) but work is lost mid-flight;
  the pushed fix code survives. Future EC2 work needs a NEW account (lava is the last one; bene died 09-11).

## BLOCKED ON MAINTAINER (nyh offline since 2026-08-03; I cannot self-merge/self-clear):
- #1464 APPROVED - waiting on a merge click.
- #1439 CHANGES_REQUESTED but STALE (all answered) - only the maintainer clears it.
- Merge queue: #1464 + #1502/#1503/#1504, then #1488 (OpenZFS 2.4.4) + #1500 (lwext4 pin), then #1478
  (native-ZFS runtime pool) + #1449 (security).

## THE KEYSTONE DECISION (unblocks the two biggest platform wins):
- #1455/#1456 fork-stack COMPOSITION. I POSTED the S1..S8 composition proposal to #1458 (comment
  5718101962). AWAITING the maintainer's call. Until then nothing in the fork generation opens as a
  mergeable PR. NO maintainer reply yet.

## TWO BIGGEST WINS - DONE ENGINEERING-WISE, blocked only on the keystone:
- LEAK #1 (fd/gfdt EMFILE) - validated, review-ready (bank/fork-fd-reap-leak-reviewready). Lands as S5.
- LEAK #2 (fork-arena memory) - 5-gate-validated (26,181 backends), banked (bank/fork-arena-real-reclaim,
  2 commits: 8 cross-AS coherence scopings + per-AS overflow reclaim). Lands as S8. Supersedes the
  grow-mitigation (retired). Pre-PR: strip the leak_probe_stats() base cruft.

## THE M1 RESULT (a2a capstone COMPLETE 2026-09-17):
- OSv SCALES (shape flipped declining->scaling). FASTER than Linux at VU8 (1.17x) + VU16 (1.29x); trails
  at VU32 median (0.72x) due to an intermittent OSv-specific cross-vCPU WAKEUP-LATENCY low-mode (proven
  via qemu-cpu discriminator; no Linux analog). io_uring both, matched HW/NVMe/ARC, libc the one caveat.

## OUR-COURT, CONDITION-GATED:
- ADAPTIVE-IDLE-SPIN fix (the wakeup-latency residual) - IN PROGRESS (agent c00cdf4d, racing lava expiry).
  If default-safe AND core/sched.cc idle path is on master -> a STANDALONE master PR (NOT fork-blocked) -
  would be the first scaling fix to reach upstream directly. Validation: isolate A/B + idle-no-regression +
  the a2a VU32 low-mode-gone gold test.
- #1501 (OSV_IDLE_SPIN) - un-drafted, ready for review, merge-clean on master (general scheduler knob).
  The adaptive fix supersedes/subsumes it; may fold together.
- #1510 (ext4 read-ahead) - DRAFT, waiting on an ext4 re-measure on current master (needs EC2 - DEFERRED
  until a new account).

## QUEUED CODE FOLLOW-UPS (not blocked):
- Fold 4b RDSEED into #1492 (after #1492 review settles).
- Rebase the NUMA family (#1438/#1441/#1445) onto master's SRAT/SLIT.

## NOT STARTED:
- M2/PGXN - DEFERRED until the wakeup-latency residual is chased (operator chose to chase it first).

## DECISIONS/CONDITIONS FOR THE OPERATOR:
1. lava expiry: a NEW AWS account is needed for any further EC2 (a2a VU64, ext4 re-measure, future benches).
   bene died 09-11, lava dying now. Flag for provisioning.
2. After adaptive-idle-spin lands: if it fixes the VU32 low-mode -> OSv leads everywhere -> M2/PGXN.
   If it only partially helps -> the residual is deeper scheduler work; decide chase-more vs M2/PGXN.

## UPDATE (sweep 4ea688fe + wakelat progress):
SWEEP: zero material change. #1458 proposal STILL no reply/reaction (maintainer offline). #1501 CLEAN on
master, awaiting first review. Deps stable. 0 EC2 orphans (report-only on dying lava, live box untouched).
osv-apps 3f93f43 current. 12 worktrees, no cruft to clean. All confirmed.
WAKELAT: the adaptive-idle-spin FIX IS PUSHED + DURABLE - gh-fork bank/sched-adaptive-idle-spin @ 4bedbfa6f
(G-signed; core/sched.cc adaptive do_idle + include/osv/sched.hh idle_spin_window; GROW-on-caught-wake/
SHRINK-on-idle-halt, Linux-halt_poll_ns-style guest-side; OSV_IDLE_SPIN_ADAPTIVE=0 = old fixed; preserves
idle_poll handshake + wake-pull + lazy-stack asserts). So the code survives lava dying = the deadline
hygiene worked. Agent now on the isolate A/B (must-finish), then idle-no-regression, then a2a VU32 gold-test
only with clear runway. lava still alive as of this check.
NOTE-ON-MERGEABILITY (sweep found): bank/sched-adaptive-idle-spin is currently STACKED on the fork-arena
leak fixes -> NOT merge-clean as a standalone yet. BUT the code is MASTER-FACING (core/sched.cc idle path
exists on master, not fork-gated). So a PRE-PR step is to RE-BASE the adaptive-spin commit onto a clean
master base (isolate it from the fork stack) -> then it is a standalone master PR, NOT fork-blocked. That
isolation is a follow-up (needs the fix validated first + ideally a live account to re-verify the build).

## WAKELAT ISOLATE A/B - v1 REFUTED (2026-09-18, measured on-box before lava expiry):
Adaptive-idle-spin v1 (symmetric grow x2 / shrink /2, floor 256, cap 10000) is WORSE than fixed-10000:
  syncwrite op/s: fixed 27200 vs adaptive 15868 (-42%); wake2ent 137us vs 274us (2x worse); p99 3484 vs
  6269us; halt_exits/s 41913 vs 86943 (2x MORE halts). DIAGNOSIS: on a constantly-halting ZIL workload the
  symmetric shrink decays the window LOW (a single halt halves it, grow-x2-from-floor cannot keep up), so
  adaptive spends LESS time in idle_poll than fixed-10000 -> fewer IPI suppressions -> more halt_exits ->
  worse latency. Backwards. The fixed-10000 + wake-pull baseline is already strong.
v2 DESIGN (asymmetric, Linux-halt-poll-style): FAST-GROW (jump toward cap on a caught wake) / SLOW-SHRINK
(only after several consecutive clean halts). Trying v2 ONLY if it fits before the 12:05 UTC terminate
margin (lava dies 12:20). If v2 also loses -> HONEST NULL: adaptive-idle-spin does not beat fixed-10000+
wake-pull on this workload; the VU32 wakeup-latency residual needs a DIFFERENT attack than idle-spin tuning.
UPDATE: v2 (asymmetric fast-grow/slow-shrink) WON where v1 lost: +65% op/s / -39% p99 / 4x fewer VM-exits
vs fixed-10000 on the isolate, matching #1501's best hand-set effect AUTOMATICALLY + host-independent.
Box terminated 11:40 UTC (40min margin), 0 orphans. Fix @ 1685b6511 G-signed, pushed, DURABLE.
HONESTY: NOT claimed as residual-fixed - the a2a VU32 low-mode-gone end-to-end test + the idle-regression
A/B are the TWO remaining gates, BOTH need a live EC2 account (deferred). v2 supersedes #1501; master-facing
(needs isolating from the fork-stack base -> standalone master PR). Full: .local/WAKEUP-LATENCY-RESULT.md.
