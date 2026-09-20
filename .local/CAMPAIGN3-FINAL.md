# Campaign 3 final: the gap is real, wider than believed, and now has named causes

2026-09-09. Four agents, all complete, **0 EC2 orphans**. Every box terminated by its own agent
except one leak I salvaged and reclaimed.

## THE HEADLINE, corrected twice

Geometry- and libc-matched Linux (32 logical = 16 phys x 2 HT on socket 0, musl PG 18.6, bare metal,
`memory.max=64GiB`, ARC capped 16 GiB and proven binding):

    VU   Linux median    OSv x86    ratio
     8      213,505       43,407      4.9x
    32      510,367       34,789     14.7x
    64      614,277 PEAK  28,377     21.6x
    96      547,813       26,047     21.0x

**Two of my conclusions overturned:**
1. Removing the confounds **widened** the gap (the old 16-vCPU/glibc reference understated Linux by
   ~2.3x). Every prior "OSv is 2.3x behind" figure was measured against a handicapped baseline.
2. **"No scaling region on Linux either" was a 16-vCPU saturation artifact.** Linux scales to VU64;
   OSv peaks at VU8 and declines. The platforms differ in **shape**, not just level, so the ratio must
   always carry its VU level.

**The asymmetry that remains favours OSv**: Linux ran with a hard 16 GiB ARC cap (proven binding)
against the guest's ~32 GiB, and was still 4.9-21.6x faster. `memory.max` did **not** bind (peak
20.3 GiB of 64), reported as a finding: memory was not the constraint on either side.

## AND MY max_wal_size PREMISE IS THROUGHPUT-DEPENDENT, NOT ABSOLUTE
    Linux at 614k NOPM:  num_timed=1, num_requested=18   <- 18 of 19 WAL-triggered, AT 64GB
    x86 OSv at ~43k:     num_timed=6, num_requested=0    <- knob worked completely
So `max_wal_size=64GB` fixes checkpoint pathology at ~100-230k NOPM and **fails at 614k**, where the
WAL rate outruns even a 64 GB budget. My framing ("64GB makes timed checkpoints dominate") was
incomplete, and it explains the >15% spread flagged at VU16/32/96 - **measured cause, not noise.**

## THE TWO CAUSES, both now named

**1. Fork/connect: FIXED, at Linux parity.** Connect median **117.3 -> 3.98 ms** on aarch64 (Linux is
4.0-4.3). Two causes in `clone_address_space()`: the O(PTEs x threads) scan, then the one I predicted
was irreducible - fork **split every 2 MB `shared_buffers` large page into 512 4K PTEs**, re-deriving
the same answer 8192 times per 16 GB. Sharing verbatim: **4,445,585 -> 132,497 PTEs**. 28/28 fork
tests pass both arms. Branch `wip/forkroot-arm-base` `5a8e946f0`, reported on #1456.

**2. The wedge: ROOT-CAUSED.** `dentry_hash_lock` (`owner=0x40032f208040, depth=1, count=8`) held by a
PG backend **asleep inside the allocator**: `dentry_lookup` -> allocation -> `l1::alloc_page` ->
blocking refill. 1,138 threads waiting, all 32 vCPUs `[halted]`, 184 backends behind the mutex, both
virtio-blk completion threads idle - which explains the 0.00% util / zero-page-fault / 26%-of-one-core
signature exactly. **Not memory exhaustion**: `global_l2._nr = 0` with **26.9 GiB free**, so fixing the
allocation-under-lock suffices. Separable second finding: **the lock is global across 32 buckets that
already exist**, which is the leading candidate for why OSv converts concurrency into queueing.

## Also landed
- **`io_method=worker` works on OSv** (proven externally: `io_method: worker`, `io_workers: 3`), and
  the blocking comment was stale. PR **osv-apps#73** updated (`5cb1903`) with that correction plus the
  `.PHONY: module build` fix for a shadowed target that silently shipped a **PostgreSQL-free image
  reporting success**.
- **io_uring is viable**: `core/io_uring.cc` is on master with every opcode PG 18 needs
  (NOP/READV/WRITEV/READ/WRITE/READ_FIXED/WRITE_FIXED/FSYNC/POLL_ADD). Needs `--with-liburing` plus
  liburing in the image, and **both arms must move together** or the confound returns.
- **#1501** replaces #1476 with a commit message that no longer carries the retracted throughput claim.
- **`conf_fork=0` build break fixed** on three branches, proven with a 2x2 compile matrix.

## Honest gaps
- **Firecracker not reached.** Task C consumed the budget and the backtrace was worth more. Stated
  plainly, not buried.
- **The malloc call site under `dentry_hash_lock` is unnamed** - truncated unwind through a
  lazily-mapped stack region. Candidates labelled unconfirmed rather than guessed.
- **`z_wr_iss`/run-queue dumps not captured**: the gdb stub stopped answering.
- **HammerDB NOPM not run on the fork-fixed base**, so whether the 3.98 ms connect win moves
  *throughput* is still untested. That is the next measurement.
