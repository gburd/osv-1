# Wakeup fan-out: mechanism REAL, fix a throughput NULL. The ceiling reframes to LWB pipeline depth.

## The measurement (agent 0fd43f40, Debian 12 host, qemu 7.2 native -M pc - q35 hangs, no fedora container)
- Commits DO batch: mean_N 3.6/5.0/7.6 at threads 8/16/32, max_N == thread count. Fan-out IS serial and
  fully under zilog->zl_lock (lockhold==fanout, ~80% is the wake loop). The traced mechanism is correct.
- **Lever 1 (hoist wakes out of zl_lock): zl_lock hold 52->7us (7x collapse), op/s +0.6% (t16) /
  +1.8% (t32) = NOISE.** No throughput lift in EITHER completion config (MQ off: 60->8us, op/s flat too).
- **Lever 3 (parallel intra-lwb wake): NOT built.** Data says it will not move throughput - waker is
  ~15% of one core (not CPU-bound), MQ_COMPLETE already parallelizes completion, and lock-removal did
  not help. Building it would be speculative against the measurement. Correct call by the agent.
- The wake-path throughput lever that DOES work is #1509 (MQ_COMPLETE): t32 OFF 11.5k -> ON 23.5k op/s,
  already ON in the m1-confirm base. On top of it, fan-out lock-hold is second-order.

## THE DECISIVE CONTROL and the reframe
nofsync 47.9k vs syncwrite 23.5k op/s, host 87-97% IDLE, waker ~15% of one core.
=> The ceiling is the per-commit DURABLE ROUND-TRIP, not a busy/serial waker. Nothing is saturated.
This explains why EVERY M1 fix has been a NOPM null (fsync-scan, dentry, #1509, fan-out): they fix real
defects but steady-state throughput is bound by the durable-commit round-trip, which none of them shorten.

## THE CONTRADICTION that names the next target
On a 90%-idle box, independent per-commit latency SHOULD let throughput scale with concurrency. It does
NOT: isolate op/s rose only ~1.3x for 4x threads (t8->t32), and HammerDB DECLINES with concurrency. So
the commits are NOT independent - something serializes them so added concurrency adds no in-flight work.
Prime suspect: **LWB pipeline depth**. If OSv effectively issues+flushes ONE lwb at a time
(zl_issuer_lock / zil_lwb_write_issue), throughput = 1/flush_latency regardless of concurrency = a flat/
declining curve on an idle box, exactly what we see. Modern OpenZFS pipelines multiple lwbs (a WRITE_DONE
lwb chains to the next); the question is whether OSv's port/config collapses that to depth ~1.

## NEXT MEASUREMENT (the real M1 frontier now)
Count LWBs concurrently in flight (LWB_STATE_ISSUED / WRITE_DONE) under the concurrent isolate. Also
whether zil_commit waiters queue behind a SINGLE open lwb. If depth ~1 -> that serialization is the
ceiling, and the fix is to let more lwbs pipeline (or issue the next lwb before the prior flush
completes). Compare to Linux ZFS lwb depth on the same workload. This is genuine upstream-ZFS territory
(zil_lwb_write_issue / zil_lwb_write_done pipeline), a generic G2 fix if OSv serializes where upstream does not.

## Lever 1 disposition
Real, safe, generic contention reduction (7x zl_lock hold cut, no regression). Filed on
contention-reduction / p99 merit, NOT a throughput claim (same honest framing as #1509). Branch pushed
by the agent (bench/zil-wake-unlocked or described in RESULT.md for extraction).

## Substrate win banked
Debian 12 + native qemu 7.2 -M pc BOOTS OSv with no fedora container and no -M pc-avoidance hack (q35
still hangs - the AHCI regression is q35-specific, not qemu-version). The operator directive substrate
WORKS. Use it for all future runs; drop the fedora:39 container from the harness.

## M1 fix ledger (all real, generic, upstreamable; NOPM-null individually because throughput is
## durable-commit-latency-bound):
#1502 dentry AB-BA | #1505 ZIL hires | #1506 ARC-max | #1507 fsync scan | #1508 physio | #1509 per-queue
completion | #1472 wake-pull default-on | Lever-1 zil-wake-unlocked (contention). Next: LWB pipeline depth.
