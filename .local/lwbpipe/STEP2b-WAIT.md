# STEP 2b — actual wait vs computed sleep: A (slow wakeup) REFUTED, issue-path is the residual

Build gh-fork/bench/lwbpipe @ f71cba013 (+ probe 0037). ZILWAIT verified in built source.

| MQ | thr | op/s   | sleep_computed | wait_actual_mean | wait_timedout_mean | mean_issue_gap | wait_max      |
|---:|----:|-------:|---------------:|-----------------:|-------------------:|---------------:|--------------:|
| 0  | 8   | 12,318 |         44 us  |          70 us   |          70 us     |     297 us     |   674,019 us  |
| 0  | 32  | 17,296 |         73 us  |          94 us   |          91 us     |     504 us     |   477,703 us  |
| 1  | 8   | 13,443 |         38 us  |          60 us   |          59 us     |     269 us     |   512,474 us  |
| 1  | 32  | 36,242 |         38 us  |          52 us   |          52 us     |     244 us     |   228,391 us  |

## A (slow hires-timer wakeup) is REFUTED.
The actual cv_timedwait_hires blocking duration (52-94us mean) closely tracks the computed sleep (38-73us)
- only ~15-30us wakeup overhead. The #1505 hires timer wakes the waiter ON TIME. So the ~2x gap is NOT a
slow/coarse timer wakeup.

## The residual bottleneck is the ISSUE PATH under zl_issuer_lock.
- Waiter waits ~52-94us, times out, calls zil_commit_waiter_timeout() -> zil_lwb_write_close() +
  zil_lwb_write_issue(). But mean_issue_gap is ~244-504us - 3-5x LONGER than the wait. The extra ~200-400us
  is spent IN the issue path, which is serialized under zl_issuer_lock (one issuer at a time):
  zio_alloc_zil (block allocation), dmu_tx_create/assign/commit, spa_config_enter, zio graph build.
- So: the pipeline stays shallow because the SERIAL issue path (zl_issuer_lock) takes ~250-500us per lwb,
  capping issue rate to ~2000-4100/s regardless of how fast flushes complete or waiters wake. Linux runs the
  same code but its issue path is faster (direct NVMe, no virtio-blk round-trips inside zio_alloc_zil's
  metaslab I/O, faster dmu_tx). This is the OSv-side cost.

## MQ_COMPLETE=1 recap (corrected, this run): the confirmed partial fix.
| thr | OSv MQ=0 | OSv MQ=1 | Linux  | MQ1/Linux | MQ1/MQ0 |
|----:|---------:|---------:|-------:|----------:|--------:|
| 8   |   12,318 |   13,443 | 32,328 |     0.42x |   1.09x |
| 32  |   17,296 |   36,242 | 51,140 |     0.71x |   2.10x |
MQ_COMPLETE=1 more than DOUBLES t32 op/s (0.34x->0.71x Linux). t8 barely moves (0.42x) - at low concurrency
the single-completion-thread was not the bottleneck; the serial issue path is.

## NEXT: measure the issue-path duration (zil_lwb_write_close+zil_lwb_write_issue under zl_issuer_lock) and
## which sub-step dominates (zio_alloc_zil / dmu_tx / spa_config_enter). That localizes the STEP-2 fix:
## if zio_alloc_zil's on-disk block allocation is doing synchronous metaslab I/O over virtio-blk -> that is
## the OSv cost and the fix is to not block the issuer on it. If dmu_tx/spa_config is the cost -> different.
## Candidate GENERIC fixes once localized: (1) ship MQ_COMPLETE=1 default-on (confirmed +2.1x t32); (2) reduce
## the per-issue serial cost so the issuer fills the pipeline. Do NOT ship the issue-path fix until localized.
