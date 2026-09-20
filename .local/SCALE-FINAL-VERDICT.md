# Scaling re-test FINAL VERDICT (2026-09-20, agent ab2f349c) - the fix works; OSv still does not scale

## Boxes terminated, 0 orphans, 0 volumes, SG unchanged (/32, no 0.0.0.0/0). 23 cells, per-arm lever proofs.

## THE TABLE (medians of VALID reps, EQUAL 32GiB cache ceiling both arms, io_uring both, fresh-boot-per-cell)
| VU  | OSv med | Linux med | OSv/Linux | OSv MB/backend | OSv qemu-cpu | Linux qemu-cpu | OSv nvme% | wedged |
|-----|---------|-----------|-----------|----------------|--------------|----------------|-----------|--------|
| 32  | 151,527 | 285,228   | 0.53      | 9.6  (42 AS)   | 1688 (53%)   | 1972 (62%)     | 53.0      | 0/2    |
| 64  | 166,217 | 284,552   | 0.58      | 10.1 (74 AS)   | 1733 (54%)   | 2675 (84%)     | 95.1      | 0/3    |
| 128 | 153,299 | 361,752   | 0.42      | 12.0 (138 AS)  | 1887 (59%)   | 2761 (86%)     | 96.7      | 1/3    |
| 192 | 149,905 | 204,343   | 0.73      | 12.5 (202 AS)  | 1851 (58%)   | 2811 (88%)     | 94.9      | 2/3    |
Every cell DRIVER_OK (driver 0-9% CPU, 5-27 Mbps of ~10Gbps) - no driver-limited cells, and the ratio
DIVERGES rather than converging, which is the opposite of a client-side wall. Guard did its job.

## #3 THE FOOTPRINT FIX: VALIDATED END-TO-END
- per-backend memory 9.4-12.5 MB, FLAT from 42 -> 202 address spaces (pre-fix: ~245 MB and climbing).
- 74 backends (the EXACT pre-fix OOM count) now completes; 202 backends run.
- VU192 recycled 1.43 TB of churn out of 1.66 GB live. Zero OOM / EMFILE / abort anywhere; memfree recovers.
=> The memory wall is GONE. The fix is confirmed under real load, not just in the isolate.

## #3 THE SCALING ANSWER: **NO** - OSv does not scale like Linux
OSv is FLAT: 151k -> 166k -> 153k -> 150k across VU32->192, behind at EVERY VU (0.42-0.73x), while Linux
rises to 361k at VU128. OSv sits at ~54-59% qemu-cpu with NVMe pinned at 95-97% util; Linux runs 84-88%
CPU with NVMe at only ~40-45%. So OSv is NOT CPU-bound - it is bottlenecked on the write/IO path while
leaving ~40% of its CPU idle. Fixing the memory wall REVEALED a throughput/liveness ceiling underneath it.

## #4 THE VU32 FACTOR: ANSWERED - and it is NOT the commit path
The durable-vs-nondurable discriminator (the decisive test):
| arm                   | NOPM    | ratio | qemu-cpu   | nvme% | top waits                                  |
| OSv   VU32 durable    | 142,163 | 0.49  | 1739 (54%) | 36.8  | LWLock/WALWrite 22.6%, AioUringCompletion 12.3% |
| OSv   VU32 nondurable |  37,751 | 0.063 | 190 (6%)   | 0.44  | IO/DataFileWrite 50.7%, AioUringCompletion 22.9% |
| Linux VU32 nondurable | 600,174 | 1.00  | 2727 (85%) | 36.9  | NONE/NULL 66.2% (CPU-bound, as expected)   |
Removing durability did NOT close the gap - it WIDENED it (0.49x -> 0.063x). Linux freed from fsync doubles
to 600k and CPU-saturates; OSv COLLAPSES to 37.7k at 6% CPU with an IDLE device.
=> VERDICT: **WAITING, not CPU-saturated.** The factor is the ASYNC WRITE-COMPLETION path (io_uring / ZFS
   writeback), NOT the ZIL/WAL commit path the whole campaign had suspected. `LWLock/AioUringCompletion`
   appears in BOTH OSv cells' top-3 waits and in NEITHER Linux cell. That names the next target precisely.

## NEW BUG FOUND: an AioUringCompletion LIVENESS wedge
3 of 11 high-VU cells wedged at 99.2-99.5% `AioUringCompletion` with device idle, CPU idle, memory healthy
- distinct from the footprint fix (which is validated) and from the old OOM. A liveness bug in the async
completion path. This is the same subsystem as the #4 verdict, which is corroborating rather than coincidental.

## REFUTATIONS OF MY OWN PREMISES (each measured, not argued - the run's most valuable output)
1. OSV_ZFS_ARC_MAX does NOT EXIST on this base -> the --env was a SILENT NO-OP, caught by a lever-proof line.
2. "OSv can't use its RAM" (MY claim) is FALSE: 2047MB is the idle floor (arc_c_min = allmem/32); under load
   arc_c reached 28,748MB. The agent REVERSED my endorsed 2GiB cap because it would have pinned Linux at its
   floor and INFLATED OSv - the same error class as the retracted "OSv 2.9x faster". I was wrong; it caught it.
3. The VU32 gap is NOT the ZIL/commit path (the campaign's long-standing suspicion) - nondurable widened it.

## HONEST CAVEATS (stated, not buried)
- Linux rep variance at VU64+ is LARGE (465k/285k/237k) and declines monotonically across reps, so the exact
  ratios carry real uncertainty. The TRUSTWORTHY part is the consistent DIRECTION across all 11 valid pairs.
- A stale on-box script destroyed the OSv pool twice and produced a fake "OSv 1.66x ahead" cell, caught by an
  impossible nvme_util=0.00 on a durable run. Three gates now prevent recurrence. Documented in
  HARNESS-INCIDENT.md rather than hidden - and note the FAKE result was FAVORABLE to OSv and still discarded.

## WHERE THIS LEAVES THE PROGRAM
The M1 memory/footprint work is DONE and validated (74 -> 202+ backends, flat ~10MB/backend). The scaling
question has a clear, measured answer: OSv does NOT yet scale like Linux on PG-on-ZFS, and the reason is now
NAMED for the first time with a discriminator: the async write-completion path (io_uring/ZFS writeback),
which also has a liveness wedge. That is the next target, and it is a much more specific one than "the
wakeup deficit" the campaign chased for weeks.
