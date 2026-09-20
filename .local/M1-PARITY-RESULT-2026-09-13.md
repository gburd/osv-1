# M1 parity: NOT MET, honestly measured. Gap = OSv WAL-commit-completion serialization.

First fully-matched, one-variable (the OS) OSv-vs-Linux PG-on-ZFS benchmark. All OSv levers on
(TCB #1504, fork, ZIL #1505, wake-pull #1472 DEFAULT-ON, fsync #1507). Same m5d.metal, same physical
NVMe, same qemu 8.1.3 KVM guest for BOTH (Linux in a matched KVM guest, not bare host - kills the
hypervisor confound). PG 18.6 musl both, 200wh/19GB, ZFS ashift=12/recsize=8k, 32 GiB ARC PROVEN
BINDING on Linux (size pinned at c_max, 100.09%), 32 vCPU, all 12 GUCs source=command line. WAKE_PULL ON.

## Headline (medians, 3 settled repeats, cold r1 voided)
    VU    OSv NOPM   Linux NOPM   ratio   delta
     8    104,640    159,792      0.655   -35%
    16     64,839    268,921      0.241   -76%
    32    WEDGED     -            -       (dentry AB-BA deadlock)
  OSv:   104640 -> 64839  = -38% then wedge (DECLINES)
  Linux: 159792 -> 268921 = +68% (SCALES cleanly)
  p99 every point (VU16 OSv NEWORD ~64-84ms vs Linux ~39-59ms); connect probe 0 samples >=1s.

## The four questions, answered straight
1. Parity? NO. 0.655x at VU8, widening to 0.241x at VU16.
2. Does OSv scale now (WAKE_PULL default-on)? NO. Still peaks at VU8, declines. WAKE_PULL did not change
   the SHAPE at 200wh - because the bottleneck is not wake-placement (nothing runnable to steal).
3. Residual gap NAMED: at VU16 Linux stays WALWrite-bound (37%) and scales; OSv's NULL-wait jumps to
   68%, device 28% util, 12/32 vCPU busy => OSv WAL-commit-completion serialization. Backends block
   waiting to be WOKEN after their commit completes. Matches the iowake ZIL-commit isolate exactly.
4. WAKE_PULL working as designed? YES. VU32 wedge top -H: all 35 qemu threads asleep, 0 runnable.
   WAKE_PULL correctly a no-op when nothing is runnable.

## #1502 PROVEN END-TO-END (a real win from this run)
The a2a base WEDGED at VU32 (true dentry AB-BA deadlock: all-asleep + 27 GiB free). Rebuilt on the SAME
box with bench/a2a-shape-fix (a2a + #1502); bench-base-gate.sh PASS (the mandatory gate, run against the
built tree - the process fix working as intended). VU32 then COMPLETED at ~62,400 NOPM across 3 cells,
NO wedge (qemu 17.9/32 vCPU busy vs 0 in the wedge). #1502 removes the deadlock end-to-end. But ~62k
stays far below Linux -> the WAL-commit ceiling PERSISTS past the deadlock. #1502 is now
throughput/scaling-qualified, not just assertion-proven - worth adding to its PR.

## What this changes about the program
- The corrected matched gap is real and NOT the 4.9x from the handicapped baseline: it is 0.655x (VU8),
  and it WIDENS with concurrency because OSv converts concurrency into WAL-commit queueing while Linux
  converts it into throughput. The methodology fix (matched, one-variable) gave an honest number in
  BOTH directions - VU8 looked better (1.5x not 4.9x), VU16 looks worse (4.1x) because Linux scales.
- The single remaining throughput ceiling is now NAMED and localized: WAL-commit-completion wakeup
  serialization on OSv. This is the next G2 target and the iowake isolate already characterized its
  shape (per-commit ZIL completion, backends serialized on the wakeup after the commit's flush).

## The next target (for the next investigation)
OSv's WAL-commit-completion path: when a backend's fdatasync/ZIL commit completes, how is that backend
woken, and why does concurrency pile up on NULL-wait rather than progressing? Candidates from the
completion-path trace: the single ZIL commit-waiter cv_broadcast fan-out, or the single virtio-blk
completion thread serializing all queues' completion wakeups. The iowake isolate (syncwrite) is the
cheap instrument to A/B any fix. This is where M1 parity will be won or lost.

## Caveats (honest)
musl both but different triples/compilers (OSv gcc-13.3 pc-linux-musl vs Alpine cc-15.2
alpine-linux-musl); ZFS 2.4.2 vs 2.4.4 (completion path identical, iowake-verified). These are small and
if anything the Alpine/newer-ZFS side slightly favours Linux; they do not explain a 4x VU16 gap.
0 EC2 orphans. Full data in .local/a2a3lever/{RESULT.md,LIVE.md,cells/,raw/}.
