# The NOPM throughput ceiling: it is the scheduler's wake-placement, and PR #1472 already fixes it.

## The chain of elimination (this whole campaign)
- ZIL commit window A/B: NULL (ruled out).
- dentry per-chain lock A/B: NULL (ruled out).
- fsync writeback-scan fix (#1507): real per-fsync/checkpoint/tail win, but NOPM NULL - a DIFFERENT
  ceiling gates peak throughput.
- The recurring signature at VU32/64 across ALL runs: ~85-90% backends wait_event=NULL, device ~13%
  util, qemu CPU ~12% of 32 vCPU, driver idle. Backends stalled waiting to be WOKEN, not on any lock,
  CPU, or device. Wedge backtrace: 32 vCPUs [halted] with an empty wakeup mask.

## Root cause (traced in core/sched.cc)
thread::wake_impl (sched.cc) always re-wakes a blocked thread on `st->_cpu` - the CPU it last ran on -
never the waker's CPU or an idle one. thread::start places a new thread on its creator's CPU. So NEITHER
wake nor spawn disperses work. The ONLY disperser is the 100ms timer load balancer. Under HammerDB, one
completion/waker thread wakes many backends onto their few home CPUs while the rest of the machine sits
idle - exactly the observed signature. (The comment at sched.cc:915 documents this precisely.)

## The fix ALREADY EXISTS, is MEASURED, and is a MERGEABLE PR: #1472
Idle-CPU PULL work-stealing: an idle CPU IPIs the busiest CPU to donate one runnable thread, instead of
waiting up to a full load-balancer tick. cpu::try_pull_from_busiest / donate_to_puller in sched.cc.
Env-gated OSV_WAKE_PULL=1 (default off - conservative; compiled in, runtime no-op unless armed).

MEASURED A/B (byte-identical pool, timed TPROC-C, arm A WAKE_PULL off vs arm B on):
    VU16: 14149 -> 15026  (+6%)
    VU32: 26722 -> 30087  (+13%)
    VU64:  7989 -> 27009  (+238%)   <- the collapse -> sustained
    VU96:  7485 -> 25697  (+243%)
    VU128: 7336 -> 24821  (+238%)
    VU192: arm A OOM (orthogonal 40wh ceiling); arm B SURVIVED 21282
Mechanism directly observed (host top -H, 32 vcpu threads): arm A collapses to R=8-10 busy past VU64
(backends piled on a few CPUs, rest idle); arm B keeps R=29-30 busy. Throughput tracks utilization.
Honest caveat recorded: p99 does NOT improve (the 8k-recordsize ZFS workload is latency-bound;
WAKE_PULL restores THROUGHPUT/UTILIZATION, not per-op latency).

## Why the recent campaign A/Bs still saw the stall
They ran with WAKE_PULL DEFAULT-OFF (the env not set). The fsync/dentry/ZIL A/Bs were each isolating a
DIFFERENT variable and left WAKE_PULL at its conservative default, so the wake-placement collapse was
present in both arms and masked each fix's effect at VU32/64. This is consistent, not contradictory: the
per-fsync scan (#1507) and the wake-placement collapse (#1472) are TWO SEPARATE defects, and #1472 is
the one that gates PEAK NOPM.

## Status / action
#1472 OPEN, MERGEABLE, merge-tree clean vs master, 3 comments (all mine, documenting validation; no
unanswered reviewer question), no review decision yet. It is the highest-value throughput PR in the
program and it is READY. The remaining question for a maintainer is whether to ship WAKE_PULL default-ON;
it currently ships default-off (safe), which means users must set OSV_WAKE_PULL=1 to get the +238%.
That is the one design decision worth raising: default-on would make the scaling fix automatic.

## The honest full picture for the north star
- #1507 fsync scan: removes a size-growing per-fsync/checkpoint tax (checkpoint 3-7x, tail -16.9%).
- #1472 wake-pull: removes the high-VU NOPM collapse (+238% at VU64), the actual throughput ceiling.
- Both generic (G2). Together they address the two OSv-side defects the PG-on-ZFS workload exposed.
- Still open: whether, with BOTH applied (WAKE_PULL armed + fsync fix), a clean matched OSv-vs-Linux
  A/B closes the gap - never measured with both on and ARC matched (#1506 enables the ARC match).
