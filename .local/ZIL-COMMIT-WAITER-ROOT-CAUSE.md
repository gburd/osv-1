# The ~264us OSv fdatasync tax is the ZIL commit-waiter timeout, and it reframes the whole ZIL story

## The decomposition (measured, single-thread, same NVMe, one variable = OS)
    workload            OSv p50   Linux p50   OSv-Linux
    syncwrite (fsync)   448.7us   185.2us     +263.5us   <- the tax
    syncwrite nofsync     6.1us     6.5us      -0.4us    <- plain write: IDENTICAL

The tax is ENTIRELY in fdatasync/ZIL commit. The general zio interrupt-taskq hop carries no
single-thread tax (nofsync matches Linux to 0.4us). **My earlier "inline the interrupt stage" design
idea is REFUTED by measurement.** Device serves each write in ~80us at ~7% util, so ~360us of the OSv
442us fdatasync is OSv-side, not device.

## Root cause (traced to zil.c, and it is the function I have been working on)
`zil_commit_waiter()` (zil.c) for an OPENED, not-yet-issued lwb does:
    sleep  = zl_last_lwb_latency * MAX(zfs_commit_timeout_pct=10, 1) / 100
    wakeup = gethrtime() + sleep
    cv_timedwait_hires(&zcw->zcw_cv, ..., wakeup, ..., CALLOUT_FLAG_ABSOLUTE)
It waits this window BEFORE issuing the lwb (upstream "responsibility 2"), so a LATER concurrent commit
can coalesce into the same lwb. **Single-threaded, there is no later commit, so the waiter waits out the
entire window on every fsync and coalesces with nothing.**

## THE IRONY that explains the null A/B
My ZIL hires fix (PR #1505, already in the base) made cv_timedwait_hires correctly HONOUR this sub-ms
window. The OLD broken tick-truncation returned immediately (sub-ms -> 0 ticks), which for a SINGLE
writer meant "issue the lwb NOW" - i.e. the broken code was accidentally FASTER for single-writer fsync.
That is exactly why OSV_ZFS_HIRES_CV ON vs OFF was ~flat in the HammerDB A/B: honouring the window helps
concurrent coalescing and hurts single-writer latency, and TPROC-C at VU8-64 is waiter-latency-dominated,
so the two effects roughly cancel. **The A/B null was not "ZIL doesn't matter" - it was two opposing ZIL
effects cancelling.** #1505 is still correct (honouring a requested deadline is right); it just is not a
throughput win on its own.

## The DECISIVE cheap test I can run next (I already built the switch)
The syncwrite isolate + OSV_ZFS_HIRES_CV=0 should make SINGLE-THREADED fdatasync FASTER if this
hypothesis holds, because =0 reverts to immediate lwb issue (no wait). Prediction:
    syncwrite OSV_ZFS_HIRES_CV=1 (honour window): p50 ~448us
    syncwrite OSV_ZFS_HIRES_CV=0 (immediate issue): p50 much lower, approaching Linux ~185us
If that holds, the tax IS the commit-window wait, and the fix is a real design question, not a bug:
**the batch window should not be paid when there is no one to batch with.**

## The RIGHT fix (generic, upstream-shaped) - to design after confirming
Upstream ZFS already has the answer in newer code: the waiter should only wait if there is a realistic
prospect of coalescing. Options, in order of upstream-alignment:
  1. If the lwb already has enough itxs / the writer is the only committer, issue immediately (skip the
     wait). Check whether upstream's zil_commit_waiter has a "commit now if no pending" fast path we are
     missing due to the 2.4.2 pin.
  2. Make zfs_commit_timeout_pct / the window adaptive to observed concurrency (0 concurrency -> 0 wait).
  3. Cap zl_last_lwb_latency so the window cannot inflate (measure it first - it may be large on OSv).
This is a GENERIC OSv/ZFS improvement (G2): every synchronous single-or-low-concurrency writer benefits.

## MUST MEASURE BEFORE IMPLEMENTING (campaign rule, two nulls already from guessing)
1. syncwrite with OSV_ZFS_HIRES_CV=0 vs =1 (confirms the window is the cost). CHEAP - reuse the box+image.
2. Read the zl_last_lwb_latency value on OSv (is the window 264us because latency is inflated, or
   because pct*latency legitimately = 264us?).
3. Diff the 2.4.2 zil_commit_waiter against upstream tip - is there a single-writer fast path we lack?
Only then implement. Re-run syncwrite (expect p50 -> ~185us) then HammerDB (expect NOPM lift AND the
null A/B finally explained as the two effects no longer cancelling).
