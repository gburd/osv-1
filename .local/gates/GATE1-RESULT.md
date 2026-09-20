# GATE 1 — idle-regression A/B (CLEAN metal measurement)

## Method
Mostly-idle OSv guest (200wh PG up, 4 idle connections each holding pg_sleep, quiescent after 2 sub-1s
CHECKPOINTs). Host CPU consumed by the qemu process measured from /proc/<qemu-pid>/stat utime+stime
jiffies delta over a fixed wall window (CLK_TCK=100). This is a REAL host counter for the qemu process,
NOT a guest guess. Fresh boot per arm. adaptive-v2 (OSV_IDLE_SPIN_ADAPTIVE=1) vs fixed-10000
(OSV_IDLE_SPIN_ADAPTIVE=0 + OSV_IDLE_SPIN=10000, the historical baseline). Spin lever confirmed from the
boot console on every arm.

## MEASURED (pasted from GATE1_RESULT console output)
| arm         | rep | window_s | delta_jiffies | cpu_core_seconds | pct_of_one_core |
|-------------|-----|----------|---------------|------------------|-----------------|
| adaptive-v2 | r1  | 120.00   | 2452          | 24.520           | 20.43%          |
| adaptive-v2 | r2  |  90.01   | 1854          | 18.540           | 20.60%          |
| fixed-10000 | r1  | 120.00   | 7754          | 77.540           | 64.62%          |
| fixed-10000 | r2  |  90.01   | 5618          | 56.180           | 62.42%          |

adaptive-v2 median ~20.5% of one core.  fixed-10000 median ~63.5% of one core.

## VERDICT: PASS (decisive)
adaptive-v2 burns ~3.1x LESS idle CPU than fixed-10000 (20.5% vs 63.5% of one core). This is the fix
working as designed: after idle_shrink_after (4) consecutive genuine halts the window HALVES toward the
floor (256), so a genuinely-idle guest decays and halts instead of spinning the fixed 10000 iterations on
every idle entry. The gate required "adaptive <= fixed + small margin"; adaptive is not merely no-worse,
it is dramatically better. On the idle-cost axis the fix is safe to promote to DEFAULT-ON.

## Note
This measures the WHOLE qemu process (32 vCPU worth of idle threads spinning). The ~20% residual under
adaptive is the floor-spin (256 iters) x 32 idle vCPUs plus PG's autovacuum/bgwriter/wal-writer timers
and the 4 idle psql backends' periodic wakeups on a mostly-idle server — expected, and far below fixed.
