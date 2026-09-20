# Adaptive idle-spin — wakeup-latency residual fix — FINAL

## Box: i-016e19e060a57409f (m5d.metal, lava us-east-2a, Owner=agent-wakelat) — TERMINATING
DEADLINE: lava expires 12:20 UTC; self-terminate by 12:05.

## DURABLE DELIVERABLE (pushed) 
- gh-fork/bank/sched-adaptive-idle-spin @ 1685b6511 (G-signed), base fork-arena-real-reclaim, apps 3f93f43.

## OUTCOME (see RESULT.md, ISOLATE-AB-RESULTS.md, PR-DRAFT.md)
- v1 (symmetric x2//2) REFUTED by measurement (-42% op/s, 2x halt_exits) + diagnosed.
- v2 (asymmetric jump-to-cap / halve-after-4-halts, cap=100000) WINS the busy isolate:
  +65% op/s (27200->44841), -43% wake2ent (137->78us), -39% p99 (3484->2118us), 4x fewer halt_exits.
- Idle-regression: proxy run INCONCLUSIVE (host /proc accounting on nested-container qemu read 0 both
  arms); idle-safety supported by construction + low busy halt rate; clean idle A/B DEFERRED to next acct.
- a2a VU32 gold-test DEFERRED (no runway; needs 200wh seed + 5 boots).

## VERDICT
Adaptive-idle-spin v2 is a measured net win on the residual's workload (busy request/reply), reaching the
#1501 high-spin effect automatically on a halt-polling host with no hand-set knob, and improving p99.
The naive design was refuted honestly. Two gates remain for a confident default-safe master PR: the clean
idle A/B and the a2a VU32 low-mode-gone confirmation — both deferred to the next account.

## Terminated + orphan check: see bottom of this file / final report.
