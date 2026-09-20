# M1 ceiling IDENTIFIED: LWB flush pipeline depth ~= 1 on OSv (upstream design is many-in-flight).

## The smoking gun (agent 0fd43f40, measured)
The zil probe's fanouts/s is PINNED at ~3000/s across a 4x concurrency increase (t8->t32); only N
(waiters/lwb) grows. throughput = fanouts/s x N = ~3000 x N. Concurrency raises the BATCH SIZE, never
the FLUSH RATE.
  ~3000 flushes/s = 333us/flush ~= nofsync p50 317us -> ONE lwb flush at a time, serially, ~333us each.
This is why every prior M1 fix was a NOPM null: fsync-scan, dentry, #1509, fan-out all fix things OFF
this critical path. The throughput ceiling is the SERIAL lwb flush rate.

## Upstream ZFS design (zil.c:3940-3950, verified): flushes SHOULD pipeline
  1. lwb ISSUANCE is serialized by zl_issuer_lock (one thread issues at a time) - correct, expected.
  2. the "previous" lwb is a CHILD of the "current" lwb via the zio parent-child graph, SO THAT
     "many lwb zio's concurrently issued to the underlying storage" complete in creation order.
So upstream INTENDS many LWB flushes in flight at once (issue serialized, FLUSH concurrent). If OSv
shows depth~1 (each flush completes before the next is issued/overlaps), OSv is SERIALIZING flushes that
upstream overlaps. That is the M1 bug and it is OSv-side in the zio/vdev/virtio-blk completion or the
zil parent-child zio wiring.

## THE GAP vs LINUX, now explained
Linux ZFS pipelines lwb flushes -> flush rate scales with concurrency -> 269k. OSv serializes to ~3000
flushes/s -> throughput = 3000 x batch_size, and batch_size saturates -> the flat/declining curve on a
90%-idle box. The device serves a write in ~80us but the ROUND-TRIP (issue -> flush -> completion ->
next issue) is ~333us serial, and only one is ever outstanding.

## TWO THINGS TO CONFIRM before touching the issue path (do NOT build first - 5 prior guesses refuted)
1. **Directly count in-flight lwbs** (LWB_STATE_ISSUED + WRITE_DONE at once) under the isolate. The
   ~3000/s pin STRONGLY implies depth~1 but confirm it directly. The probe is baked in (bench/zilwake).
2. **Why does OSv serialize?** Candidates, to trace:
   (a) the virtio-blk FLUSH: does a VIRTIO_BLK_T_FLUSH block the queue / force a barrier so the next
       lwb write cannot issue until the prior flush completes? (single completion thread was #1509;
       but the FLUSH ordering is separate.)
   (b) the zio parent-child wiring in OSv's vdev_disk: is lwb_root_zio -> flush chained so the next
       lwb's write waits on the prior's flush, collapsing the pipeline to depth 1?
   (c) zil_commit_waiter_timeout / the batch-window forcing one-at-a-time issue (the ZIL hires fix
       #1505 area - honouring the window could be serializing issue).
   (d) ARC/txg or a single zio taskq stage that flush zios funnel through serially.

## THE FIX SHAPE (once confirmed): let lwb flushes overlap
Allow the next lwb to issue (its write + flush zio) while the prior lwb's flush is still in flight,
per the upstream parent-child design. If OSv's vdev_disk or virtio-blk serializes flushes, fix that
ordering. Generic upstream-ZFS-conformance fix (G2): every concurrent-fsync workload benefits.
Expected: fanouts/s RISES with concurrency (not pinned at 3000), isolate op/s scales, HammerDB NOPM
finally moves. This is the first candidate that targets the ACTUAL critical path, not something off it.

## Lever 1 (zil-wake-unlocked, bench/zil-wake-unlocked @ 1fe51340c) stands as a filed contention fix
(7x zl_lock hold cut, p99/variance merit, not throughput). Keep it.

## Substrate: Debian 12 + native qemu 7.2 -M pc boots OSv (no fedora container). Directive validated.

## THE FIX RUN (agent c1576ec2, 2026-09-15) - measure-localize-fix-benchmark, on Debian
Local source trace narrowed but did NOT resolve the serializer (that is why it needs measurement):
  - zil.c wiring correct (zio_add_child enforces completion ORDER, not issue serialization)
  - vdev_disk FLUSH async (strategy(bio), no wait)
  - virtio-blk FLUSH a normal request, no barrier
  => depth-1 is EMERGENT. Candidates: commit-window timing (#1505), zl_issuer_lock hold, flush-
     completion dependency, zl_last_lwb_latency sleep. Agent localizes empirically.

## THE VALIDITY GATE that decides the fix (built into the brief)
Before blaming OSv, measure the LINUX lwb flush rate on the SAME NVMe:
  - Linux >> 3000/s  -> OSv PIPELINE bug confirmed -> fix = concurrent lwb flushes.
  - Linux ~3000/s but BIGGER batches -> the DEVICE serializes flushes (physics) -> fix = BATCHING.
  - Linux ~3000/s + same batch -> premise wrong, gap elsewhere -> report, redirect.
This prevents "fixing" a device-physics limit or shipping a pipeline change when batching is the answer.
The instance-store NVMe cache-flush COULD be a device-wide serial barrier; Linux's 269k proves either it
is not, or Linux rides more commits per flush. The measurement decides.

## SUCCESS CRITERION (root cause closed, not just a fix that compiles)
STEP 4 HammerDB: OSv (fix on) vs Linux, matched, must show OSv STOPS DECLINING VU16->VU32 and NOPM
rises materially toward Linux. That - not the isolate alone - is the proof the root cause of the
disparity is solved. If OSv still declines, the fix did not close it and we say so and keep looking.
  agent-lwbpipe: i-0b054feb76fe528cb (m5d.metal, Debian 12, us-east-2a) - STEP 1 measurements running

## STEP 1a RESULT (agent c1576ec2): strict depth-1 REFUTED, ceiling REFRAMED to flush COMPLETION RATE
Direct in-flight lwb depth on OSv (syncwrite t8/16/32, same NVMe):
    inflight MAX = 6/8/11 (grows with concurrency)   MEAN = 1.4/1.8/1.5
So flushes DO overlap (up to 11 at once) - the upstream parent-child pipeline WORKS on OSv. NOT a
depth-1 serialization bug. Good: one more plausible hypothesis refuted by direct measurement.
BUT flush RATE pinned ~3000/s and DECLINES under load: 3219 -> 2994 -> 2564/s (t8->t32). op/s scales
~2x (11.6k->24k) ONLY via batch size (mean_N 3.6->9.4). Device only ~20% util at t32 - NOT saturated.

## The corrected diagnosis: a COMPLETION-RATE ceiling that WORSENS with concurrency
~11 flushes in flight, device 20% idle, yet only ~3000 complete/s and the rate DROPS as load rises.
More in flight -> fewer completing -> a contention/serialization point in the flush COMPLETION path
that gets WORSE with concurrent flushes. A device cache-flush barrier would give a FLAT rate; a
DECLINING rate points at an OSv-side lock/queue/single-threaded completion stage.

## STEP 1b is now THE discriminator (steered to capture the full contrast)
Measure Linux-ZFS on the SAME NVMe: flush rate AND commits-per-flush, at t8 AND t32.
  - Linux rate HOLDS/RISES t8->t32 while OSv DECLINES -> OSv completion-path contention, fixable in OSv.
  - Linux ~3000/s too but bigger batches -> device barrier -> fix = batch more per flush.
  - Linux ~same -> premise wrong, redirect.
The t8-vs-t32 rate CONTRAST (Linux holds vs OSv declines) is the cleanest evidence. No fix until 1b.

## STEP 1b DECISIVE (agent c1576ec2): ROOT CAUSE = OSv issuer not filling the lwb pipeline
Linux-ZFS vs OSv-ZFS, SAME NVMe, SAME zil.c, SAME batch size:
    Linux: 8335 flush/s, batch 3.78, ~99 lwbs IN FLIGHT (t8)
    OSv:   ~3000 flush/s, batch 3.62, ~1.5 lwbs in flight (t8)
NOT device physics, NOT batching, NOT transport. throughput = flush_rate x batch; Linux ~2.9x on flush
rate alone = the entire ~3x steady-state gap. The OSv ISSUER issues one lwb then waits ~one-flush-
latency (mean_issue_gap ~286us) before the next -> depth stays ~1.5. Linux issues the next IMMEDIATELY
-> fills to ~99.

## The mechanism (traced in zil.c ~3168-3176): zl_parallel not latching to ZIL_BURSTS on OSv
zl_parallel = ZIL_BURSTS iff the prev lwb is still OPENED/not-FLUSH_DONE when checked (workload looks
multi-threaded). OSv keeps hitting the else (prev ALREADY FLUSH_DONE) -> zl_parallel decays -> issuer
stops aggregating -> depth collapses to ~1. Both OSes run identical code -> the difference is a TIMING
INPUT making OSv think commits do not overlap when they do. Prime suspect: zl_last_lwb_latency measured
too small on OSv (clock/units, ties to #1505) -> commit-waiter sleep ~= latency*pct/100 ~= 0 -> waiter
issues immediately, no batch window held, prev lwb flushes before next commit -> zl_parallel never latches.

## Partial fix already MEASURED (real, shippable): OSV_BLK_MQ_COMPLETE=1 (#1509)
+40% flush/s (t32 2579->3621), +33-38% op/s. Leaves ~2x residual -> the issuer-pacing fix is the rest.
So #1509 default-on gains value here: it is part of the throughput fix, not just isolate/correctness.

## STEP 2 target (steered): instrument zl_last_lwb_latency + the commit-waiter computed sleep +
## zl_parallel branch-hit-rate at t8/t32. Fix = make the window/latency correct so the issuer aggregates
## and fills the pipeline like Linux. Do NOT ship until the WHY (why zl_parallel does not latch) is named.
## Then STEP 3 isolate A/B (depth + flush/s + op/s rise) and STEP 4 HammerDB (OSv scales VU16->VU32).

## This is the FIRST diagnosis proven ON the critical path with a Linux contrast: OSv 1.5 vs Linux 99
## lwbs in flight is the single cleanest number of the whole M1 campaign. The fix is now localization
## of WHY zl_parallel does not latch, not a search for the layer.

## STEP 2 (agent c1576ec2): window + issuer-pacing REFUTED; residual localized to the lwb WRITE
Two more clean refutations by measurement (both were my/prior suspects):
  - commit WINDOW (zfs_commit_timeout_pct): widening HURTS (t8 op/s 13295@pct10 -> 6237@pct100, depth
    DROPS 6->3). Batching refuted.
  - issuer pacing: waiter wakes on time (~60us), serial issue path tiny (~14us). Neither is the cost.
Latency split of the ~380us whole-lwb: ZIL block WRITE (issue->WRITE_DONE) ~256-279us = ~70%; FLUSH
(WRITE_DONE->FLUSH_DONE) only ~110-123us (healthy for local NVMe). By Little's law (depth fixed ~1.4)
the ONLY rate lever is cutting the ~270us WRITE. An 8k sync WRITE at ~270us on a device that FLUSHes in
110us is ~2x too slow = the OSv-vs-Linux write-path gap.

## THE SHARPEST CONTRAST (to nail): plain pwrite ~6us vs lwb sync-WRITE ~270us on the SAME device
The syncwrite nofsync path already measured plain 8k writes at ~6us. If the lwb WRITE is 270us on the
same NVMe, the ~264us delta is almost ENTIRELY OSv-side zio-pipeline overhead (ABD handling, taskq hops,
extra zio stages, a synchronous wait in the write pipeline), NOT the device and NOT the flush. Naming
that zio stage is the fix target for the residual. (Follow-up run builds it; this run localizes it.)

## DECISION (operator): lock in the confirmed win, then bounded residual hunt.
1. MQ_COMPLETE default-on = +2.1x t32, 0.34x -> 0.71x Linux (matched). CONFIRMED, SHIPPABLE - captured
   to RESULT.md, and it turns #1509 "default on" from a judgment call into a measured 2.1x throughput
   win. This ALREADY closes most of the M1 gap (0.71x Linux at t32, was 0.24x).
2. Bounded (~60-90min) split of the 270us write into virtio-blk round-trip vs zio-pipeline overhead;
   name the stage; do NOT build this run. Then terminate (<=5h total).

## M1 STATUS UPDATE: the gap is LARGELY CLOSED by an existing fix defaulted on.
MQ_COMPLETE (#1509) default-on takes t32 from 0.34x to 0.71x Linux. That is the headline: the per-queue
completion fix, which HammerDB-nulled at 200wh earlier BECAUSE the base already had it on, is worth 2.1x
on the durable-write isolate and is the single biggest M1 lever found. The remaining 0.71x->1.0x is the
~270us lwb-write zio-pipeline overhead - a named, localized follow-up. #1509 should ship default-on.

## CORRECTION to the note above (do NOT conflate isolate with HammerDB) - operator self-check
I wrote "the M1 gap is LARGELY CLOSED by MQ_COMPLETE default-on (0.71x Linux)". That OVERREACHED.
The 0.71x is an ISOLATE (pure pwrite+fdatasync storm) number. On HammerDB TPROC-C at 200wh, the earlier
#1509 A/B (SINGLE vs PERQ) was a clean NULL (+4.6% noise). SAME switch, opposite results. The likely
reconciliation: the isolate SATURATES the flush-completion-rate path where MQ_COMPLETE helps (+2.1x);
TPROC-C is a MIX (reads, think-time, fewer concurrent durable commits) and does NOT push that path to
saturation, so MQ_COMPLETE is null THERE - TPROC-C is bound elsewhere (the NULL-wait per-commit
round-trip). HONEST POSITION:
  - MQ_COMPLETE (#1509) is a real +2.1x on a durable-write microbenchmark and worth defaulting on.
  - It does NOT close the M1 HammerDB gap (that A/B nulled). The M1 verdict is the HammerDB scaling
    test, unchanged.
  - The ~270us lwb-WRITE residual (zio-pipeline overhead, plain-write 6us vs lwb-write 270us same
    device) is the localized real cost, and whether cutting IT moves HammerDB is UNPROVEN - it must be
    re-tested on HammerDB, not assumed from the isolate.
Do not report "M1 largely closed". Report: root cause of the ISOLATE flush-rate gap localized to the
lwb-write zio overhead; #1509 default-on is a measured microbenchmark win; HammerDB parity NOT yet
demonstrated and requires the write-path fix + its own HammerDB confirmation.
