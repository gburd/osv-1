# STEP 1b REFINED — corrects the "~99 in flight" artifact; per-lwb depth pairing

The earlier Linux depth used kprobe:zil_lwb_write_issue which fires ONCE per call but the call issues 1+ lwbs
(next_lwb loop) -> unreliable (drifted to 99 / negative). REDONE with per-lwb pairing:
  kprobe:zil_lwb_write_done   (fires once/lwb, flush issued)  -> inflight++
  kprobe:zil_lwb_flush_vdevs_done (fires once/lwb, flush done) -> inflight--

## Corrected reliable numbers (direct-Linux, same nvme1n1, zfs 2.1.11)
| thr | op/s   | flushes/30s | flush/s | inflight_MAX (per-lwb) |
|----:|-------:|------------:|--------:|-----------------------:|
| 8   | 32,328 |     212,303 |   7,077 |                    3   |
| 32  | 51,140 |     125,065 |   4,169 |                    3   |

## THE "99 in flight" WAS AN ARTIFACT. Both OSes run SHALLOW depth.
- Linux inflight_max = 3 (t8 and t32). OSv inflight_max = 6/8/11-14. Comparable order of magnitude, both shallow.
- So the gap is NOT "Linux keeps 99, OSv keeps 1.5". Correction to my prior notify_parent: Linux depth ~3, not ~99.
- Per Little's law at t8: Linux 7077 flush/s / depth~3 => ~424us per flush; OSv 3495 flush/s / mean-depth~1.4
  => ~400us per flush. Per-flush SERVICE TIME is ~the same (~400-424us) on both.
- => The ~2x flush-rate gap comes from OSv sustaining a LOWER MEAN in-flight depth than Linux at the same
  per-flush latency. Linux keeps the pipeline ~2x fuller ON AVERAGE.

## So the operator's zl_parallel lead is the RIGHT target, restated precisely:
Both run identical zil.c. Per-flush latency is equal. OSv's issuer keeps fewer lwbs in flight on average ->
lower flush rate. The pipeline-fill decision is zl_parallel (zil.c ~3168): OPENED->ZIL_BURSTS;
prev!=FLUSH_DONE->ZIL_BURSTS/2; else decay. If OSv hits the decay branch more (prev lwb already FLUSH_DONE
when checked), it stops aggregating and depth stays low. Root suspects: zl_last_lwb_latency wrong/small ->
commit-window sleep ~0 -> issue-immediately -> prev flushes before next commit -> zl_parallel never latches.

## NEXT (STEP 2 hunt, per operator): instrument on OSv at t8/t32:
(a) zl_last_lwb_latency actual value (should be ~300-400us, the flush latency; if ~0 -> clock/units bug),
(b) the sleep the commit-waiter computes (zl_last_lwb_latency * zfs_commit_timeout_pct/100),
(c) how often the commit-writer loop hits zl_parallel=ZIL_BURSTS vs the decay branch,
(d) OSv mean in-flight depth vs Linux mean in-flight depth (not just max).
Do NOT ship until we can point at WHY zl_parallel does not latch / the window is not held.

## NOTE: the @flat_us latency histogram in this run is INVALID (zio ptr reuse aliases the issue->done map,
## giving a bogus 128us..16s spread). Ignore it. inflight_max + flushes count are the valid outputs here.
