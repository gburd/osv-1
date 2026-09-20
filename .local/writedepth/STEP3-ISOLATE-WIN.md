# STEP 3 QUALIFY - OSV_IDLE_SPIN isolate A/B: the upstream-faithful recycle fix WINS

Isolate: syncwrite t8/16/32, 3x30s, same m5d.metal raw /dev/nvme0n1, MQ_COMPLETE=1.
A = OSV_IDLE_SPIN=10000 (default), B = OSV_IDLE_SPIN=500000 (idle CPUs spin longer before halting so a
woken committer's home vCPU catches the wake in its spin loop instead of halting -> IPI/VM-exit).

| thr | spin    | lwb-depth mean | inflight_max | wake2ent us | issue_gap us | op/s   | vs A     |
|-----|---------|----------------|--------------|-------------|--------------|--------|----------|
|  8  | 10000   | 1.38           | 6            | 65.8        | 315.3        | 11930  | -        |
|  8  | 500000  | 1.42           | 7            | **30.5**    | **119.9**    | 28633  | **+140%** |
| 16  | 10000   | 1.70           | 8            | 81.4        | 286.5        | 18815  | -        |
| 16  | 500000  | 1.57           | 7            | **47.6**    | **130.8**    | 40310  | **+114%** |
| 32  | 10000   | 1.45           | 16           | 131.8       | 302.9        | 30737  | -        |
| 32  | 500000  | 1.62           | 11           | **73.4**    | **187.0**    | 48000  | **+56%**  |

Linux baseline (same device): t8 ~25000, t16 ~34500, t32 ~45700-48632 op/s.
=> With OSV_IDLE_SPIN=500000, OSv REACHES/EXCEEDS Linux: t8 28633 (>Linux 25k), t16 40310 (>Linux 34.5k),
   t32 48000 (== Linux ~45.7-48.6k).  The isolate gap (was 0.48-0.70x) is CLOSED on the isolate.

## The honest mechanism (NOT "depth rose"):
lwb-depth MEAN barely changed (~1.5 both arms).  The win is RECYCLE SPEED, not concurrency:
- wake2ent (flush-wake -> next committer entry) HALVED: 66->31, 81->48, 132->73us.
- issue_gap ~= round-trip dropped 315->120, 286->131, 303->187us.
- issues MORE THAN DOUBLED (t8 290k->767k) at the same ~1.5 depth.
So the single-committer-in-caller model (identical to Linux) recycles ~2.5x faster once the halted-vCPU
wake VM-exit is avoided.  This is EXACTLY the parent's upstream-faithful lever: shrink the loop input
(the OSv wake+reschedule cost, lever b), NOT a dedicated issuer (upstream has none), NOT a cap raise.
The write-service floor (~195us, lever a) is unchanged and NOT the throttle at these rates.

## Which loop input shrank and by how much:
wake2ent (the OSv cross-vCPU wake of the next committer) cut ~50%: t32 132->73us.  That, applied to
every recycle, dropped the effective issue_gap ~40% and doubled+ the issue rate.  The device write
(~195us) was left untouched and did not need touching for the isolate win.

## CAVEAT before HammerDB: OSV_IDLE_SPIN burns CPU on genuinely-idle vCPUs.
The isolate is ZIL-bound with idle vCPUs to spin.  HammerDB TPROC-C uses CPU for query execution; a long
idle-spin could steal cycles from PG work OR could still net-win by cutting per-commit wake latency.
This must be tested, not assumed - HammerDB is the verdict.  This lever is on the per-commit critical
path (every WAL commit's fdatasync recycles through this wake), so it PLAUSIBLY transfers - but the
idle-spin CPU cost is a real risk the isolate does not capture.
