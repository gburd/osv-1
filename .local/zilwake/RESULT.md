# ZIL post-commit wakeup fan-out: MEASURED, localized, Lever-1 A/B'd

BOX: **i-08d7381c36de61059** (m5d.metal, us-east-2a, Owner=agent-zilwake) — TERMINATED (see end)
Host: Debian 12 (bookworm), ami-0dc1629a58a7d6458, qemu 7.2.22 native, /dev/kvm.
Guest: 32 vCPU / 64 GiB. Pool: single instance-store NVMe /dev/nvme1n1 (virtio-blk,
num-queues=32), ashift=12, recsize=8k, sync=standard. NO postgres, NO HammerDB.
Branch: gh-fork/bench/zilwake @ d89f88689 (m1-confirm base + probe patch 0034 + Lever-1).

## SUBSTRATE NOTE (Debian directive)
qemu 7.2.22 boots OSv NATIVELY (no fedora:39 container). BUT `-M q35` HANGS right
after virtio-blk init (before the bench main() prints) on this device layout - the
q35 AHCI regression is NOT fully absent on Debian 7.2 here. `-M pc` boots and runs
clean. All runs below are `-M pc`, native qemu, no container.

## PROBE VERIFICATION (the swallowed-error trap)
The Makefile's single `git apply <all-patches>` is atomic-per-invocation: if any
DEPENDENT patch fails its pre-flight check, git applies NOTHING and the stamp is
still (in the old code) never touched, silently leaving ZFS unpatched. Confirmed:
0032 (ARC-OOM sync shrinker, authored against a header-less zfs_initialize_osv.c
that 0009 no longer produces) fails to apply on this branch. Fix: apply patches
ONE AT A TIME with a --recount retry + a loud skip log (Makefile change, pushed).
VERIFIED the probe is in the BUILT source: `grep -c zilwake_dump|OSV_ZIL_WAKE_UNLOCKED|zw_fanouts
modules/open_zfs/openzfs/module/zfs/zil.c` = 9, and `nm -D libsolaris.so | grep zilwake_dump`
= `T zilwake_dump` (exported). Only 0032 skipped (irrelevant to a no-mem-pressure isolate).

## STEP 1 - MEASURE (fix OFF; MQ_COMPLETE=1 = the m1-confirm base state; secs=20 reps=3)
threads | agg op/s | mean_N | max_N | mean_fanout_us | wakeloop_us | lockhold_us | wakeloop_frac
   8    |  9,936   | 3.57   |   8   |    22.7        |   18.3      |   22.4      |   0.805
  16    | 15,829   | 5.03   |  16   |    45.4        |   36.0      |   45.1      |   0.793
  32    | 23,523   | 7.57   |  32   |    49.0        |   38.9      |   48.7      |   0.795
(reps=5 confirm at t32: baseline median 21,834 op/s, mean_N=7.53, mean_fanout=52.5us.)

DISCRIMINATION (the four questions the plan asked):
1. Do commits batch under concurrency?  YES. mean_N 3.6 -> 5.0 -> 7.6, max_N tracks
   thread count EXACTLY (8/16/32). A single lwb batches many commits. HYPOTHESIS NOT
   REFUTED (this is the case that would have redirected if N~1 - it is not N~1).
2. Fan-out time vs N?  GROWS with N (22.7 -> 45.4 -> 49.0us). The serial loop cost scales.
3. Is the wake loop the bulk of the fan-out?  YES, ~80% at every thread count (wakeloop_frac
   0.79-0.81). The SERIAL WAKE LOOP dominates the fan-out. -> Lever 3 signal.
4. Is the fan-out held under zl_lock (blocking the next commit)?  YES - lockhold == fanout
   (48.7 vs 49.0us at t32). The ENTIRE fan-out is under zl_lock. -> Lever 1 signal.

Both levers are implicated by the timing. Device+host NOT the ceiling: host vmstat
87-97% idle during the t32 run (matches the M1 "device+CPU idle at the plateau" shape).

## STEP 2 - A/B  Lever 1 (OSV_ZIL_WAKE_UNLOCKED): drain waiters under zl_lock, DROP lock, wake outside
                       op/s        mean_lockhold_us   mean_wakeloop_us(under lock)   wakeloop_frac
  t16 baseline    | 15,829      |  45.1            |  36.0                       |  0.793
  t16 Lever-1     | 15,931      |   5.8  (7.8x v)  |   1.3                       |  0.033
  t32 baseline r5 | 21,834      |  52.3            |  41.8                       |  0.796
  t32 Lever-1 r5  | 22,221      |   7.3  (7.2x v)  |   1.6                       |  0.036

RESULT: Lever 1 does EXACTLY what it was designed to do to the LOCK - it collapses the
zl_lock hold 7.2-7.8x (52->7us), because the wake fan-out is no longer inside the lock;
only the cheap list-drain remains under it. BUT aggregate op/s moves +0.6% (t16) / +1.8%
(t32) - within run-to-run noise (stdev ~530-2000 op/s).

## VERDICT (honest, measured)
- The post-commit wakeup fan-out IS on the hot path and IS serial: one completion thread
  walks N=3.6..7.6 waiters per lwb, ~80% of the fan-out time is the serial wake loop.
- The zl_lock HOLD across the fan-out is real and Lever 1 removes it cleanly (7.2x), which
  should reduce zl_lock contention / p99 variance and is a safe, generic, correct change -
  but it is NOT the aggregate-throughput gate at the isolate level: the lock hold falls 7x
  and op/s barely moves.
- The gate is therefore the SERIAL WAKE ITSELF (Lever 3), not the lock: even outside the
  lock, N backends are still woken one-after-another on ONE completion thread. Duty-cycle
  check: at t32 ~3200 fanouts/s x 47us = ~15% of ONE core in the wake loop - the waker is
  NOT CPU-saturated, so the cost that matters is the per-wake WAKE LATENCY (thread::wake +
  IPI to a halted vCPU) serialized on one thread, adding wake latency to every commit while
  32 backends sit in NULL-wait. That is what keeps op/s flat with CPU+device idle.

## COMPLETION-THREAD PARALLELISM IS THE REAL LEVER (and it is ALREADY ON in the M1 base)
Control A/B at t32, secs=20 reps=3, Lever-1 OFF:
  MQ_COMPLETE OFF (single virtio-blk completion thread): 11,527 op/s, mean_fanout 60us
  MQ_COMPLETE ON  (per-queue completion, #1509/walwake):  23,523 op/s, mean_fanout 49us
-> Per-queue completion ALONE DOUBLES t32 throughput. This is the walwake/#1509 win and it
   is already in the m1-confirm base. On TOP of it, the ZIL fan-out lock-hold is second order.

Lever-1 with MQ_COMPLETE OFF (single completion thread, where the lock-hold should bite most):
  base   11,527 op/s, lockhold 59.9us
  Lever1 10,474 op/s, lockhold  8.0us (7.5x v)   -> lock removed, throughput NOT up (noise/down)
Lever 1 does not lift throughput in EITHER completion-thread configuration. Decisive: the
zl_lock hold across the fan-out is genuinely not the aggregate-throughput gate.

## WHERE THE CEILING ACTUALLY IS (nofsync control)
  syncwrite (ZIL commit round-trip): 23,523 op/s, p50 1145us
  nofsync   (write-only, no commit):  47,879 op/s, p50  317us
The durable-commit round-trip halves throughput and ~4x's p50 - and it does so with host
CPU 87-97% idle and the completion waker only ~15% of one core. The commits sit in
NULL-wait on the per-commit ZIL write->flush->completion LATENCY, not on a saturated waker
and not (post-MQ) on the wake fan-out being serial.

## FINAL VERDICT (measured, refutes part of the premise)
1. Commits DO batch (N up to 32) and the fan-out IS serial + lock-held - both premises hold.
2. Lever 1 (hoist the wake out of zl_lock) is a CORRECT, SAFE, GENERIC change: it collapses
   the zl_lock hold 7.2-7.8x, which cuts zl_lock contention and should tighten p99 on any
   fsync-concurrent workload. KEEP IT. But at the isolate it does NOT raise op/s (+0.6..1.8%,
   noise) in either completion-thread config.
3. Therefore the post-commit wake fan-out SERIALIZATION is NOT the M1 throughput ceiling once
   per-queue completion (MQ_COMPLETE / #1509) is on - and it IS on in the M1 base. The big
   wake-path throughput lever was the completion-thread count (already applied), not the
   intra-lwb wake loop.
4. Lever 3 (parallelize the N intra-lwb wakes) was NOT built: the data says it will not move
   throughput - the single waker is only ~15% of one core, MQ already spreads fan-outs across
   32 threads, and removing the lock (Lever 1) did not help. Building it would be speculative
   against the measurement. The residual ceiling above 23.5k op/s is the per-commit durable
   round-trip latency (nofsync sustains ~48k), a different lever than the wakeup fan-out.

## WHAT TO CONFIRM WITH HAMMERDB (operator runs separately)
- Lever 1 is generic; expect it to help p99/latency-variance under fsync concurrency more than
  raw TPS. If HammerDB at 200wh shows 77-87% NULL-wait AND MQ_COMPLETE is ON, Lever 1 alone is
  unlikely to lift TPS materially - matches the isolate. If it DOES lift TPS, the PG commit
  pattern (group commit, more waiters/lwb, longer wake chains) differs from the isolate and
  the lock-hold matters more there than here; the probe (zilwake_dump / RESULT ZILWAKE) is in
  the image to check N and lockhold under the real workload.

ENV: OSV_ZIL_WAKE_UNLOCKED=1 (Lever 1, default off), OSV_BLK_MQ_COMPLETE=1 (per-queue completion).
FILE: modules/open_zfs/patches/0034-*.patch -> module/zfs/zil.c zil_lwb_flush_vdevs_done().
BRANCH: gh-fork/bench/zilwake @ d89f88689.

## FILED: Lever 1 as a standalone, probe-free, honestly-scoped patch
The measured Lever-1 logic (drain waiters under zl_lock, drop the lock, wake outside) is
filed on its own branch as a clean patch WITHOUT the probe instrumentation:
  gh-fork/bench/zil-wake-unlocked @ 1fe51340c
  modules/open_zfs/patches/0034-zfs-wake-ZIL-commit-waiters-outside-zl_lock-OSV_ZIL_.patch
This is the SAME drain-then-wake code the probe build A/B-validated, minus the counters -
so it is measurement-backed, not an untested rewrite. Filed on CONTENTION-REDUCTION merit
(7x zl_lock-hold drop, no throughput regression), explicitly NOT a throughput claim - the
same honest framing as #1509. Safe: each zcw is unlinked from the lwb before the lock drop;
zil_commit_waiter_done() takes only the per-waiter zcw_lock, never zl_lock, so no ordering
hazard. Default off, resolved value printed once. The probe patch (0034 on bench/zilwake)
stays separate as bench-only tooling and is baked into the benchmark image.

## PROBE IN THE IMAGE (for the next question, under the real workload)
zilwake_dump() (exported T in libsolaris.so) prints two lines the bench reads after any
syncwrite run: `RESULT ZILWAKE fanouts/waiters_total/mean_N/max_N/lockhold/wakeloop/fanout`
and `RESULT ZILWAKE_NHIST` (N bucketed 1/2/3-4/5-8/9-16/17-32/33+). Same image can be booted
under PostgreSQL/HammerDB (it is on bench/zilwake); OSV_ZIL_WAKE_UNLOCKED toggles Lever 1 and
the dump reports the mode, so a dropped env cannot read as "no effect".

## NEXT-MEASUREMENT LEAD (do NOT chase now - what the data already implies)
The flat-scaling puzzle (op/s only ~1.3x for 4x threads on a 90%-idle box; HammerDB DECLINES)
is NOT the wake fan-out. The probe's fanouts/s rate points straight at LWB PIPELINE DEPTH:

  threads | fanouts/s (=lwb-flush completions/s) | mean_N (waiters/lwb) | op/s
     8    |  2772                                |  3.58                |  9,936
    16    |  3162                                |  5.00                | 15,829
    32    |  3055                                |  7.69                | 23,523

The lwb-flush completion rate is PINNED at ~3000/s across a 4x concurrency increase. The ONLY
thing that grows with concurrency is N (waiters packed into each lwb). So throughput
= (lwb flush rate ~3000/s, ~constant) x (waiters per lwb, the only thing that scales). Added
backends do NOT add in-flight lwbs; they just batch harder into the same ~3000 flushes/s.
That ~3000/s == ~330us per flush, which matches the nofsync p50 (317us) - i.e. throughput is
pinned at ~1/flush_latency, the signature of a SERIAL lwb issue/flush pipeline (depth ~= 1:
zl_issuer_lock / zil_lwb_write_issue issuing+flushing roughly one lwb at a time). That fits
flat-on-idle-box AND declines-with-concurrency exactly, where independent per-commit latency
would SCALE. NEXT measurement (operator to run separately): instrument how many lwbs are
concurrently in LWB_STATE_ISSUED/WRITE_DONE (pipeline depth), and whether zil_commit waiters
queue behind a single open lwb via zl_issuer_lock. If depth ~= 1, THAT is the M1 ceiling, not
the wakeup fan-out - and the fix is pipelining lwb issue/flush, not the wake path.
The current probe captured this only indirectly (fanouts/s); it does NOT yet count concurrent
in-flight lwbs - that is the instrument to add next.
