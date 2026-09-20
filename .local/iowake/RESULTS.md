# Per-durable-write latency tax: OSv-ZFS-on-NVMe vs Linux-ZFS-on-NVMe

Box: i-00f11bfe4f947797d  m5d.metal  us-east-2  Owner=agent-iowake  (TERMINATED, see end)
Date: 2026-09-12
NVMe (both arms, same physical device): /dev/nvme1n1 (838 GiB instance-store)
One variable: the OS. Everything else matched.

## Matched configuration (verified on both arms)
Pool geometry: ashift=12, recordsize=8k, compression=off, atime=off,
               sync=standard, logbias=latency, primarycache=all
Guest (OSv arm): 8 vCPU / 8 GiB, KVM, -M pc, qemu 8.1.3 (fedora:39 container).
NVMe attach (OSv): virtio-blk-pci, format=raw, cache=none, aio=native (vblk1).
Workload: single thread, 8k pwrite [+ fdatasync], secs=30, reps=3.
  syncwrite            = pwrite + fdatasync each  (total per-durable-write cost)
  syncwrite nofsync=1  = pwrite only              (write-completion cost, no ZIL/flush)

## ZFS version note (the one imperfection in "one variable")
OSv arm:   OpenZFS 2.4.2 (submodule 6330a45b, the in-tree openzfs).
Linux arm: OpenZFS 2.3.4 (built against running kernel 6.12.103).
The zio completion architecture (zio_interrupt -> ZIO_TASKQ_INTERRUPT taskq ->
zio_done -> cv_signal) is identical across 2.3.x and 2.4.x, so this does not
affect which completion hop the tax lives in. Flagged for honesty.

## RESULTS (medians of 3 reps; microseconds per op)

| workload              | OSv p50 | OSv p99 | Linux p50 | Linux p99 | dOSv-Linux p50 | dOSv-Linux p99 |
|-----------------------|--------:|--------:|----------:|----------:|---------------:|---------------:|
| syncwrite (fsync)     |  448.7  |  917.5  |   185.2   |   282.5   |   +263.5       |   +635.0       |
| syncwrite nofsync     |    6.1  |   47.8  |     6.5   |    15.9   |     -0.4       |    +31.9       |

Raw reps:
  OSv  syncwrite     p50 [448.3, 448.7, 460.3]  p99 [911.5, 917.5, 922.1]  ops/s ~2205
  OSv  nofsync       p50 [2.9, 6.1, 6.2]        p99 [47.0, 47.8, 48.3]     ops/s ~96810
  Linux syncwrite    p50 [181.9, 185.2, 186.3]  p99 [281.9, 282.5, 283.5]  ops/s ~5149
  Linux nofsync      p50 [6.4, 6.5, 6.6]        p99 [14.7, 15.9, 20.9]     ops/s ~140584

## The decomposition (this is the point)

Plain write-completion (nofsync) p50 is IDENTICAL: OSv 6.1 us vs Linux 6.5 us
(delta -0.4 us, i.e. zero). The general zio interrupt-taskq completion hop
carries NO measurable OSv tax at single-thread QD1.

The ENTIRE tax is in the fdatasync / ZIL-commit-completion path:
  OSv  fsync cost = 448.7 - 6.1  = 442.6 us
  Linux fsync cost = 185.2 - 6.5 = 178.7 us
  OSv excess in the ZIL-commit path = 442.6 - 178.7 = ~264 us per durable write.

This is the design-analysis case:
  "syncwrite >> but nofsync ~= Linux  =>  the tax is specifically in the
   ZIL/flush-commit completion path.  Fix target: the ZIL commit-completion
   wakeup."
NOT the general interrupt-taskq hop (case a): that would have shown up in
nofsync too, and it did not.

## Device / CPU state during OSv syncwrite (confirms the HammerDB finding)
Host iostat on /dev/nvme1n1 while OSv single-thread syncwrite runs:
  %util ~6.5-7.5 %   w_await ~0.08 ms (80 us)   ~1660-1775 w/s
The device serves each write in ~80 us and is ~93% idle, yet the per-op
latency is ~448 us. The ~370 us gap between device service time and observed
latency is pure OSv-side completion/wakeup overhead - and per the split above,
it is incurred in the fdatasync (ZIL commit) completion, not the plain write.

qemu host CPU during the single-threaded workload: ~150% (1.5 cores) across
12 threads. A single-threaded, mostly-waiting workload burning 1.5 cores is the
wakeup-churn signature: the ZIL-commit durable write is bounced across the OSv
blk-completion thread, the INTERRUPT taskq thread(s), and the txg/ZIL threads,
each an extra scheduler wakeup, on an otherwise-idle guest where each wakeup is
a cross-thread (and often cross-vCPU IPI) round trip.

## What this means for the fix (stated straight)
The per-transaction OSv latency tax is real, reproducible in single-thread
isolation, and localized: it is in the ZIL commit-completion wakeup path, not
the general block-I/O interrupt-taskq completion hop and not the plain
write-completion path.

Fix target (to validate next, not yet implemented): the ZIL/flush commit
completion wakeup - the cv_signal that unblocks the fdatasync caller when the
ZIL commit zio (and its flush) completes. That is where ~264 us of the ~370 us
OSv-side overhead is spent per durable write. The generic "run zio interrupt
stage inline on the blk completion thread" idea (case a) is NOT supported by
these numbers: nofsync write completion already matches Linux, so inlining the
generic interrupt stage would move nothing.

## HammerDB reconciliation
The ~0.44 ms/8k end-of-recovery checkpoint write measured earlier matches the
OSv syncwrite p50 of 448.7 us here exactly - so the checkpoint number was a
ZIL-commit-completion cost, and this isolate reproduces it. It is NOT purely a
concurrency/scheduling effect (case c); it reproduces single-threaded. The
VU32/64 "device idle + CPU idle + backends cycling in wait_event=NULL" ceiling
is consistent with every backend paying this ~264 us ZIL-commit wakeup tax per
commit while the device sits ~90% idle.
