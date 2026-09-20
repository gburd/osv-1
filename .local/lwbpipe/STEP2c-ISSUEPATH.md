# STEP 2c — issue path is FAST (~14us); the cadence is set by the commit WINDOW, not any serial cost

Build gh-fork/bench/lwbpipe @ e4f21db88 (+ probe 0038). MQ_COMPLETE=1. ZILISSUEPATH verified in built source.

| thr | op/s   | mean_issue_gap | issue_path_us | alloc_us (zio_alloc_zil) | dmutx_us | mean_depth |
|----:|-------:|---------------:|--------------:|-------------------------:|---------:|-----------:|
| 8   | 14,148 |     250.7 us   |     13.7 us   |          6.7 us          |  8.5 us  |    ~1.42   |
| 32  | 34,001 |     260.9 us   |     15.7 us   |          5.7 us          |  9.7 us  |    ~1.48   |

## The serial issue path is NOT the bottleneck (REFUTES STEP-2c hypothesis).
zil_lwb_write_issue takes only ~14-16us per lwb (zio_alloc_zil ~6us, dmu_tx ~9us). It is NOT the ~250us gap.
So none of: flush completion parallelism (fixed by MQ), hires wakeup (52-94us, on time), OR the serial
issue path (~14us) accounts for the ~250us inter-issue gap.

## Full accounting of the ~250us mean_issue_gap:
  waiter wait window ~52-94us  +  issue path ~14us  =  ~70-110us of "work" per issue
  but mean_issue_gap = ~250-261us  =>  the issuer is IDLE ~150-190us between issues.
By Little's law this is self-consistent: mean depth ~1.4, flush latency ~400us => flush rate =
1.4/400us = 3500/s => issue_gap = 285us. The system is depth-limited at ~1.4, and depth is ~1.4 because a
new lwb is only ISSUED when a waiter TIMES OUT (window ~40-90us), and waiters accumulate/aggregate only as
fast as the ~40us window + flush completion allow.

## THE ACTUAL LEVER: the commit window (zfs_commit_timeout_pct) interacting with flush latency.
- OSv uses zfs_commit_timeout_pct=10 (upstream default); the computed window = lwblat*10/100 = ~40us.
- With 81-94% of waiters timing out at ~40us, aggregation is minimal - each lwb carries ~3.6-9.4 commits
  then force-issues. A LARGER window would let more commits accumulate per lwb (bigger batches -> more op/s
  per flush) - the BATCHING lever. Alternatively the window is structurally capping issue cadence.
- This is the same knob family as #1505 (delicate). MUST A/B zfs_commit_timeout_pct (e.g. 10 -> 30 -> 50 ->
  100) and measure op/s AND p50/p99 (a larger window raises per-commit latency; the win must beat that).

## Candidate fixes now, in priority (both GENERIC, upstream-conformant, env-gated):
1. OSV_BLK_MQ_COMPLETE=1 default-on -- CONFIRMED +2.1x t32 (0.34x->0.71x Linux). Ship regardless.
2. zfs_commit_timeout_pct larger/adaptive -- test next; the batching lever the numbers point to.
## Do NOT ship #2 until the A/B shows op/s up AND p99 acceptable.
