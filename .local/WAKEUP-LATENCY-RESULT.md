# Wakeup-latency residual - adaptive idle-spin v2: NET WIN on the residual's workload (2026-09-18)

## Delivered under the lava-expiry deadline (box terminated 11:40 UTC, 40min margin before 12:20 expiry, 0 orphans)
gh-fork bank/sched-adaptive-idle-spin @ 1685b6511 (G-signed). core/sched.cc (adaptive do_idle) +
include/osv/sched.hh (idle_spin_window, idle_halt_streak). Base bank/fork-arena-real-reclaim, apps 3f93f43.

## ROOT CAUSE -> CONTROL
send_wakeup_ipi() suppresses the cross-vCPU wake IPI iff !idle_poll. The bug was the FIXED spin count
(10000): halt-just-before-wake -> IPI/VM-exit (the VU32 low-mode). FIX = adaptive per-CPU window (Linux
halt_poll_ns, guest-side): JUMP TO CAP on a caught wake, HALVE only after 4 consecutive genuine halts,
cap=100000, floor=256. Asymmetric fast-grow / slow-shrink.

## MEASURED (isolate A/B, syncwrite-mt 32 writers, 30s x3, qemu 7.2.22, host halt_poll_ns=200000):
| arm                        | op/s          | wake2ent us | p99 us      | halt_exits/s   |
| fixed-10000 (old default)  | 27200         | 137         | 3484        | 41913          |
| adaptive v1 (symmetric)    | 15868 (-42%)  | 274         | 6269        | 86943 (REFUTED)|
| adaptive v2 (asymmetric)   | 44841 (+65%)  | 78 (-43%)   | 2118 (-39%) | 11039 (4x fewer)|
v1 was measured to LOSE (symmetric decay oscillates the window low -> polls less than fixed -> more IPIs),
correctly diagnosed, v2 WON: +65% op/s, -39% p99, 4x fewer VM-exits, lowest halt rate - matching the best
hand-set #1501 spin AUTOMATICALLY, and on a halt-polling host (where fixed #1501 was host-conditional).

## HONESTY GATE (held): do NOT claim the residual is "fixed" - the a2a VU32 low-mode-gone data was NOT
## obtained (no runway; needs the 200wh seed + 5 boots -> deferred to a new account). What IS proven with
## pasted measured output: adaptive-idle-spin v2 is a net win on the residual's workload (the durable-write
## isolate) + master-applicable. TWO gaps deferred to next account: (1) the a2a VU32 gold-test (does the
## low-mode disappear end-to-end), (2) the idle-regression A/B (the proxy read 0 on both arms in the nested
## container - INCONCLUSIVE, not proof; idle-safety supported by construction + the low busy halt rate).

## STATUS: strong measured win on the isolate; the end-to-end M1 confirmation (VU32 low-mode gone) + the
## idle-no-regression proof are the two remaining gates, both needing a live EC2 account. PR-DRAFT.md ready.
## Supersedes #1501 (fixed OSV_IDLE_SPIN) - v2 gets #1501's best effect automatically + host-independent.
## MASTER-FACING: core/sched.cc idle path is on master; needs isolating from the fork-stack base (currently
## stacked) -> then a standalone master PR, NOT fork-blocked.
