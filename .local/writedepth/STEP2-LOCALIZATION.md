# STEP 2 LOCALIZATION - WHERE the one-at-a-time lwb issue comes from (RESULT ZILCOMMIT)

Baseline (all levers off), t8/16/32, 3x30s, correct-pin build with 0041+0042 probes.

| thr | committers_max | itx_per_lwb_mean/max | lwbs_per_pass_mean | c2i_us_mean | issue_gap_us | lwb-depth mean | svc_us | op/s |
|-----|---------------|----------------------|--------------------|-------------|--------------|----------------|--------|------|
|  8  | **1**         | 6.78 / 16            | 0.395              | 14.0        | 303          | ~1.37          | 187.7  | 12109 |
| 16  | **1**         | 9.54 / 32            | 0.402              | 59.6        | 283          | ~1.69          | 204.6  | 18150 |
| 32  | **1**         | 16.47 / 61           | 0.440              | 57.7        | 288          | ~1.52          | 207.7  | 32059 |

## THE ANSWER: committers_max = 1 at ALL thread counts.
Only ONE thread is ever inside zil_commit_writer processing the commit list.  This is the parent's
hypothesis (c) confirmed: OSv backends serialize on zl_issuer_lock and only one committer is ever active.

## What this rules IN and OUT:
- Aggregation WORKS: itx_per_lwb_mean scales 6.8 -> 9.5 -> 16.5 (max up to 61). OSv batches many itxs
  per lwb - it is NOT issuing one-itx-per-lwb. So "narrow batches" is NOT the problem.
- Issue is FAST: c2i (commit-entry -> first lwb issued) is only 14-60us. Producing an lwb is cheap.
- ~60% of writer passes issue ZERO lwbs (lwbs_per_pass_mean ~0.4): most committers find their waiter
  already committed by the single active committer and early-bail. Correct ZFS behavior.
- The throttle is NOT the vdev-queue cap (vqwrite <1), NOT zl_parallel decay (low), NOT the batch
  window (pct sweep null), NOT batch width (wide). It IS: committers_max=1 + issue_gap ~= round-trip.

## The mechanism (the OSv-specific serialization):
With exactly ONE committer active at a time and issue_gap ~285us ~= the lwb round-trip (svc ~200us +
flush), the pipeline is: single committer issues lwb N -> releases zl_issuer_lock -> waits (its fdatasync
blocks on lwb N's flush) -> lwb N completes ~285us later -> wakes a waiter -> that thread re-enters
zil_commit as the next committer -> issues lwb N+1.  So lwbs issue ~one round-trip apart, depth ~1.4.
On Linux the SAME code keeps ~13 lwbs in flight because MANY threads re-enter and issue successive lwbs
while prior ones are still outstanding - i.e. Linux sustains multiple effective committers/re-entries per
round-trip, OSv sustains ~1.

## WHY only 1 committer on OSv (the root, ties to parent 1a/1b):
The single committer issues lwb N via zio_nowait (async, non-blocking) and RETURNS from
zil_commit_writer immediately (c2i ~14-60us) - it does NOT hold the lock for a round-trip.  So the lock
is FREE ~285us out of every ~285us.  Yet no OTHER thread issues lwb N+1 in that window.  That means the
other N-1 threads are NOT arriving at zil_commit_writer with pending itxs during the window - they are
BLOCKED in zil_commit_waiter on their own prior lwb's flush.  It is circular: a thread can only become
the next committer after its previous fdatasync returns (its lwb flushed).  With depth ~1.4, only ~1-2
threads are "free" to commit at any instant; the rest wait.  The low re-entry rate = low depth = few
free committers = low re-entry.  Linux breaks the loop because its per-lwb round-trip is shorter AND its
wakeups are cheaper, so threads cycle back into zil_commit fast enough to sustain many concurrent
in-flight lwbs.

## The lever this names (for STEP 2 fix, guardrail-compliant):
Do NOT raise a cap.  The fix must let successor lwbs issue while prior ones are in flight WITHOUT needing
a just-flushed thread to re-enter.  Options (A/B):
 (i) A dedicated issuer that keeps draining the itx commit-list and issuing lwbs back-to-back while any
     itxs are pending, decoupled from the per-thread fdatasync wait (the committer does not have to be a
     waiting backend).  This is what would raise concurrent-in-flight lwbs at the SAME service time.
 (ii) Cheaper/faster wakeup of the next committer (parent 1b: OSv cross-vCPU wake cost) so the re-entry
     loop cycles faster - shrinks issue_gap toward the flush interval, raising depth.
Both must preserve zl_issuer_lock serialization of ISSUE (only one issues at a time is FINE - Linux does
that too) and the parent-child zio ordering.  The win is more OUTSTANDING lwbs, not concurrent issuers.
