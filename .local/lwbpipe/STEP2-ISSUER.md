# STEP 2 issuer instrumentation — the mechanism, measured

OSv build gh-fork/bench/lwbpipe @ da82cd7da (+ probe 0036). syncwrite t8/t32, MQ off and on. Verified in
built source: ZILISSUER_IN_SRC=1, zp_decay=4, MQ_COMPLETE=4.

| MQ | thr | op/s   | zp_open | zp_prevnf | zp_decay        | lwblat_mean | sleep_mean | timedout / sleeps      |
|---:|----:|-------:|--------:|----------:|----------------:|------------:|-----------:|------------------------:|
| 0  | 8   | 11,917 | 156,061 |   76,295  |  19,027 (7.6%)  |    438 us   |    46 us   | 334,892 / 357,517 = 94% |
| 0  | 32  | 19,352 |  97,201 |   53,031  |   2,714 (1.8%)  |    660 us   |    66 us   | 472,214 / 580,614 = 81% |
| 1  | 8   | 12,763 | 167,867 |   83,750  |  19,101 (7.1%)  |    393 us   |    41 us   | 358,762 / 382,910 = 94% |
| 1  | 32  | 36,064 | 174,398 |  103,593  |   1,971 (0.7%)  |    377 us   |    39 us   | 886,145 /1,081,973 = 82%|

## What is REFUTED (operator suspects 1 and 3):
- zl_parallel DOES latch: zp_open dominates every case, decay branch is rare (0.7-7.6%). The issuer correctly
  detects "multi-threaded" and sets zl_parallel=ZIL_BURSTS. NOT a decay problem.
- zl_last_lwb_latency is REALISTIC (~377-660us ~= the true flush latency). NO clock/units collapse. The #1505
  hires timeout is feeding a sane latency. So suspect (1) "lwblat collapsed to ~0" is REFUTED.

## What IS happening (the real mechanism):
- The commit-window sleep = zl_last_lwb_latency * zfs_commit_timeout_pct/100 = ~400us * 10/100 = ~40us.
- 81-94% of commit waiters TIME OUT at that ~40us window and force-issue their own lwb via
  zil_commit_waiter_timeout(), rather than being signalled by natural aggregation. So aggregation is largely
  NOT happening via the "more activity closes the lwb" path; it happens via each waiter timing out.

## The KEY GAP the numbers expose (this is the fix target):
- The waiter COMPUTES a ~40us window, but the ACTUAL mean inter-issue gap is ~280-458us (RESULT ZILDEPTH
  mean_issue_gap_us) - ~7-10x LONGER than the computed sleep. So the waiter intends to wait 40us but the
  effective issue cadence is ~300-450us. That excess (40us intended -> ~300-450us actual) is an OSv-side
  wakeup/scheduling cost in the cv_timedwait_hires timeout -> wake -> run-issuer path. THAT is where OSv
  loses ~2x vs Linux: the waiter cannot time-out-and-issue fast enough, so mean in-flight depth stays ~1.5.

## NEXT: measure the ACTUAL waiter wait duration (enter cv_timedwait_hires -> return) vs the 40us computed
## sleep, at t8/t32. If actual >> computed -> the hires-timeout wakeup latency (or scheduler delay to run the
## timed-out waiter and have it issue) is the OSv-side cost. Two candidate fixes then:
##   (A) if the wakeup/timer is the cost: make the timed-out-issue path cheaper/faster (the #1505 hires area),
##       or issue proactively without waiting for every waiter to time out.
##   (B) if the window itself is wrong: with 81-94% timeouts the window is doing nothing useful - a
##       longer/adaptive window would aggregate MORE per lwb (bigger batches, fewer flushes) OR a proper
##       zero-wait "issue immediately when the device can take another flush" fill would raise depth. Must
##       A/B both and measure p99 (raising the window raises per-commit latency).
## Do NOT ship until the actual-wait-vs-computed-sleep number pins A vs B.

## NOTE: MQ=1 t32 = 36,064 op/s here (vs 32,097 in the earlier MQ A/B) - MQ_COMPLETE=1 confirmed strong at
## t32 (~+86% over MQ=0 t32 19,352). MQ_COMPLETE=1 stays the confirmed partial fix regardless of the issuer work.
