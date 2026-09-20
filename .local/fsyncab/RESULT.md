# fsync-writeback A/B — HammerDB TPROC-C end-to-end result

## The question
Does removing OSv's O(filesize) per-fsync pagecache scan (`writeback_inode`
whole-file scan, core/pagecache.cc) lift TPROC-C NOPM? Same-binary A/B, ONE
variable: `OSV_PAGECACHE_FSYNC_SCAN` (unset/0 = guard ON = FIXED; =1 = old scan = OLD).

## Answer, stated straight
**NOPM: NULL at every VU tested.** FIXED and OLD are within run-to-run spread at
both VU8 (47188 vs 48745, -3.3%) and VU32 (33420 vs 32192, +3.8%). The microbench
per-fsync win does NOT translate into a steady-state TPROC-C NOPM lift at these VUs.

**BUT the scan cost is unmistakably real and lands on two other axes:**
- **Checkpoint cost:** OLD arm's first post-run checkpoint EXPLODES and grows with
  DB/WAL size (VU8: 168 -> 249 -> 438s run-over-run; VU32: 616s). FIXED stays flat
  (~50-86s). A 3-8x (VU8) to 7x (VU32) reduction in checkpoint duration.
- **Tail latency:** at VU32, FIXED NEWORD P99 = 58.6ms vs OLD 70.5ms (**-16.9%**).
- **Wait profile (VU8, arm medians):** OLD backends spend MORE time on the
  WAL-fsync serialization (LWLock/WALWrite 40.1% vs 24.2%) and are LESS idle
  (NULL 44.7% vs 62.6%) — the predicted mechanistic direction: the fix eases the
  WAL-fsync serialization.

So: the fix does not raise peak throughput on this workload, but it removes a
real, size-growing per-fsync/checkpoint tax that hits checkpoint duration and tail
latency. It stands on the isolate (3.5-4.3x lower fdatasync p50, flat with file
size) + correctness merits + these secondary end-to-end wins. **I will NOT claim a
NOPM throughput win — the numbers do not show one.**

## The A/B was valid (two DIFFERENT console PGCFLAG lines, same image)
    FIXED boot: PGCFLAG OSV_PAGECACHE_FSYNC_SCAN default (guard on)
    OLD   boot: PGCFLAG OSV_PAGECACHE_FSYNC_SCAN=1 (old scan)
Same image (OSV_SHA 89016d843, APPS 3f93f43, ZFS 6330a45b), same 200wh/19GB ZFS
pool (ashift=12, recsize=8k, sync=standard), same 12 GUCs (all source=command line
verified from driver), same guest (32 vCPU/64GiB). Only the boot --env differed.

## Headline tables

VU8 (3 settled repeats/arm, r1 void as cold-inflated):
    VU   FIXED median   OLD median   delta%   ratio
    8    47188          48745        -3.3%    0.968   (NULL, within 2.7-13.5% spread)
  wait: FIXED WALWrite 24.2% / NULL 62.6%   OLD WALWrite 40.1% / NULL 44.7%
  checkpoint: FIXED ~50-58s flat   OLD 168->249->438s (grows with size)

VU32 (short-run settled pair, 1 repeat/arm — guest instability blocked 3x):
    VU   FIXED   OLD     delta%   NEWORD-P99 F/O    checkpoint F/O
    32   33420   32192   +3.8%    58.6 / 70.5 ms    86s / 616s
  wait: both ~85-90% NULL (idle-stall dominates at VU32; masks the WAL-fsync wait)

VU64: NOT RUN. See substrate ceiling below.

## Refinement-2 (does the delta GROW with VU?)
Inconclusive on NOPM (null at both VUs). On the axes where the fix DOES show:
- Checkpoint tax grows with DB size within the OLD arm (438s at VU8 late runs,
  616s at VU32) — consistent with the O(filesize) mechanism.
- The WAL-fsync wait shift is LARGER at VU8 (16pp) than VU32 (2pp), because at VU32
  an arm-independent internal idle-stall (~85-90% NULL) dominates and masks it.
  So the fsync-wait signal is clearest at LOW VU here, opposite the naive prediction
  — because the high-VU regime is gated by a different (OSv-internal) bottleneck.

## Substrate ceiling (honest limitation)
Under sustained FULL-LENGTH VU32 load the OSv guest wedges in BOTH arms:
- FIXED VU32 full-length: guest network died (ETIMEDOUT, no OOM, no crash) — a
  hang, not a crash.
- OLD VU32 full-length: hard OOM ("could not reclaim any further, Current memory
  37657188 Kb" of 64GiB), fault dump, guest dead.
Diagnostics during the one full-length OLD VU32 cell that completed: driver CPU
98% idle, NVMe %util 15%, qemu CPU dropping to 0% of one core mid-window. Nothing
external is saturated — the bottleneck is an OSv-internal scheduler/network stall
(the same ~90%-NULL device+CPU-idle regime prior null runs hit). Short runs
(rampup1/dur3) fit inside the wedge-free window and gave the VU32 pair above.
The wedge is ARM-INDEPENDENT: not caused by the fsync fix.

## Boxes (Owner=agent-fsyncab, lava, us-east-2) — ALL TERMINATED, 0 orphans
- METAL i-0ae60ac03c7f72bbc  m5d.metal   -> terminated, root vol vol-040e7db27afc95f7a DELETED
- DRV   i-05d7034dfaaae8350  c5.2xlarge  -> terminated
- Final: 0 live tagged instances, 0 tagged volumes, 0 volumes attached to either id.

## Filing guidance
File PR pr/fsync-writeback-guard (master-facing) with the isolate table (flat p50,
3.5-4.3x lower) as the primary evidence. Cite the HammerDB run as: NOPM neutral at
VU8/VU32, but 3-7x lower checkpoint duration and -17% NEWORD p99 tail latency in
the fixed arm, with the WAL-fsync wait share dropping — i.e. the fix removes a
real size-growing per-fsync/checkpoint tax without regressing throughput. Do NOT
headline a NOPM win.
