# STEP 2a: commit-window pct sweep - NULL as a depth fix (do not ship)

OSV_ZIL_COMMIT_TIMEOUT_PCT sweep (0=default 10, plus 1/2/5/30/60), t8/16/32, 3x30s. Uses the 0039 patch,
zero new code. Question: does changing the commit-batch window raise the SUSTAINED lwb-depth mean + op/s?

| thr | pct | depth-mean* | issue-gap us | vqwrite mean | inflight_max | issues | op/s |
|-----|-----|-------------|--------------|--------------|--------------|--------|------|
|  8  | 10  | ~1.36       | 298          | 0.88         | 6            | 307k   | 12335 |
|  8  | 1   | ~2.73       | 155          | 1.30         | 8            | 587k   | 13473 (+9%) |
|  8  | 60  | ~0.50       | 906          | 0.73         | 3            | 100k   | 9084 (-26%) |
| 16  | 10  | ~1.68       | 259          | 0.95         | 9            | 352k   | 19910 |
| 16  | 1   | ~2.7        | 185          | 1.23         | 16           | 502k   | 18386 (-8%) |
| 32  | 10  | ~1.43       | 289          | 0.94         | 14           | 323k   | 32755 |
| 32  | 1   | ~1.85       | 248          | 1.02         | 22           | 378k   | 30227 (-8%) |
| 32  | 2   | ~1.83       | 249          | 1.03         | 23           | 371k   | 30801 (-6%) |
(*depth-mean = depth_integral_ns / ~90s wall)

## VERDICT: pct is NOT the depth fix.
- Lowering pct DOES shrink the issue-gap (298->155us at t8) and raise inflight_MAX (14->22 at t32) and
  the mean integral - BUT the vqwrite (device-queue) mean stays ~1.0-1.3 and op/s does NOT rise; it
  FALLS 6-8% at t16/t32. Only t8 gains +9%.
- Lowering the window just creates MORE, SMALLER lwbs (issues 307k->587k at t8) without building a
  deeper SUSTAINED device pipeline. The extra per-lwb issue/flush overhead costs op/s at higher thread
  counts. inflight_max rises because bursts happen, but steady-state overlap does not.
- Raising pct (aggregate more) monotonically tanks depth and op/s (bigger batches, longer waits).

This confirms guardrail #1: the throttle is NOT a tunable number / batch window. The queue would accept
more (cap 10 unhit), the issuer intends to aggregate (decay low), yet successor lwbs are not OUTSTANDING
concurrently - they are issued ~one-round-trip apart (gap ~= service+flush) regardless of window. The
window controls lwb GRANULARITY, not pipeline DEPTH.

## NEXT: instrument WHERE the one-at-a-time issue comes from (parent guardrail #1a/b/c):
 - itxs committed per zil_lwb_write_issue pass (batch width) - OSv vs the implied Linux width.
 - concurrent committers: how many threads are inside zil_commit_writer/holding zl_issuer_lock vs
   waiting on a flush at once (the circular low-depth: few concurrent committers -> low re-entry).
 - the gap decomposition: after lwb N issues, is the issuer thread (a) not re-entered until the prior
   flush wakes a waiter (round-trip serialization), or (b) waiting on a scheduler wake (OSv IPI cost)?
