# #4 THE VU32 FACTOR — durable-vs-nondurable discriminator RESULT (equal cache, matched box)

## The four measured cells (all DRIVER_OK, all validity-gated, fresh boot each)
| cell | NOPM | ratio OSv/Linux | qemu_cpu /3200 | nvme %util | dominant wait |
|---|---|---|---|---|---|
| OSv   VU32 durable    | 142,163 | **0.49** | 1739 (54%) | 36.8 | LWLock/**WALWrite** 22.6%, AioUringCompletion 12.3% |
| Linux VU32 durable    | 290,379 | 1.00 | 1714 (54%) | 28.4 | LWLock/**WALWrite** 51.1% |
| OSv   VU32 nondurable |  37,751 | **0.063** | **190 (6%)** | 0.44 | IO/**DataFileWrite** 50.7%, AioUringCompletion 22.9% |
| Linux VU32 nondurable | 600,174 | 1.00 | **2727 (85%)** | 36.9 | NONE/NULL 66.2% (CPU-bound) |

## What this PROVES, and it is NOT what the brief predicted
Removing durability did NOT close the gap — it WIDENED it, 0.49x -> 0.063x. So by the brief's
own decision rule this is **Outcome B: the gap is not the ZIL/WAL commit path**. But the
nondurable arms are not a subtle version of the same regime; they are a different bottleneck
on each side, and that is the finding:

- **Linux nondurable behaves as expected**: freed from per-commit fsync it becomes
  CPU-SATURATED (qemu_cpu 2727/3200 = 85%, wait profile goes to NONE/NULL 66%) and throughput
  DOUBLES 290k -> 600k. Textbook: durability was its limiter, remove it and CPU becomes the limit.
- **OSv nondurable COLLAPSES instead**: 142k -> 37.7k with qemu_cpu falling to 190/3200 (6% of
  one core across 32 vCPU) and nvme %util 0.44. The guest is neither CPU-bound nor IO-bound —
  it is WAITING. The wait profile relocates to IO/DataFileWrite 50.7% + AioUringCompletion 22.9%.

## The named factor: OSv's ASYNC WRITEBACK / AIO-COMPLETION path, not the commit path
With fsync on, WAL commits serialize the workload on both sides, which MASKS the real OSv
deficit. Remove that serialization and Linux's dirty-buffer writeback absorbs the load
(io_uring completions retire fast, CPU saturates), while OSv's does not: work piles into
DataFileWrite waiting on AioUringCompletion, the CPU goes idle, and throughput falls below its
own durable number. The deficit is in how OSv retires ASYNCHRONOUS BUFFERED WRITE COMPLETIONS
(the pagecache/ZFS writeback + io_uring completion path), and AioUringCompletion appearing as
a top-3 wait in BOTH OSv cells (12.3% durable, 22.9% nondurable) and in NEITHER Linux cell is
the OSv-specific fingerprint.

This also explains the durable VU32 gap coherently: at equal cache and equal CPU allocation
(both arms ~54% qemu_cpu in the durable cells) OSv does 0.49x the work — consistent with a
per-write-completion cost that is paid on every dirtied buffer, partially hidden behind fsync
serialization but never absent.

## CPU-saturated vs waiting (the split the brief asked for)
**WAITING, decisively, and it gets worse as the workload is freed to go faster.** OSv never
approaches CPU saturation at VU32 in either mode (54% durable, 6% nondurable) while Linux does
(54% -> 85%). So this is NOT a cycles-per-transaction/path-length gap; it is a
latency/blocking gap in write-completion handling. That retires the "general CPU cost"
hypothesis (Outcome B1) and lands on B2.

## Honest scope
- One rep per cell so far; the ratios are directional, not final medians. The qemu_cpu split
  (6% vs 85%) is far too large to be rep noise, but the NOPM values will get reps.
- fsync=off is a MECHANISM PROBE, not a throughput claim for either system.
- The prior a2a attributed the VU32 gap to an intermittent cross-vCPU wakeup-latency low-mode.
  These numbers are compatible with that being the SAME underlying deficit observed from a
  different angle: a wake/completion that arrives late leaves the guest idle-waiting, which is
  exactly the 190/3200 signature. The nondurable cell turns an intermittent low-mode into the
  steady state, which is a much better handle for the fix than waiting for it to bite.
