# THIRD CAUSE FOUND: global TLB-flush serialization

Found by agent f18ef8dd (which then wedged after establishing it; box reclaimed by
me). Root cause confirmed independently by me in the source.

## The finding

`arch/x64/mmu.cc`:

    mutex tlb_flush_mutex;                    // SINGLE file-scope global
    sched::thread_handle tlb_flush_waiter;    // SINGLE global waiter
    std::atomic<int> tlb_flush_pendingconfirms;

    void flush_tlb_all()
    {
        ...
        SCOPE_LOCK(migration_lock);
        mmu::flush_tlb_local();
        std::lock_guard<mutex> guard(tlb_flush_mutex);   // <-- guest-wide serialization
        tlb_flush_waiter.reset(*sched::thread::current());
        ...IPI every other CPU, then BLOCK until all confirm...
    }

So **every TLB broadcast in the entire guest serializes through one mutex**, and the
holder blocks waiting for cross-CPU IPI confirmations from all other vCPUs. There is
exactly one `tlb_flush_waiter`, so no two broadcasts can even be in flight at once.

The header comment is candid about the cost: "This is slow, but necessary for
correctness so that, for example, after mprotect() returns, no thread on no cpu can
write to the protected page."

## Why this matches every symptom measured

With 32 PostgreSQL backends faulting on shared_buffers, each COW fault that needs a
global flush queues on that single mutex behind a holder that is itself waiting on
32-way IPI round-trips:

- **global simultaneity** - all backends release together when the queue drains
  (per-VU MAX clustered within 3 ms across ~30 of 32 VUs)
- **CPU-bound, disk idle** - virtio inflight 1-2 vs 60, io_ticks 39/s vs 218, while
  qemu CPU DOUBLED to ~2200-2600%: the guest is spinning on IPI confirmations and
  lock handoffs, not waiting on storage
- **sync=0.009 s vs write=86-154 s** - ZFS commits instantly; the time is in
  *submitting*, i.e. in the fault/flush path above it
- **throughput-triggered** - more throughput means more faults means more contention
  on the one global mutex; throttling PG with observers made it vanish
- **not fork, not I/O** - an already-connected session doing only `select 1` still
  stalled, because it too can need a TLB broadcast
- **31 backends on LWLock:WALWrite while IO:WalSync <= 2** - the WALWrite holder was
  stuck in the flush path while everyone queued behind the LWLock

## Why the first two fixes did not close the gate

Each removed a real serialization point but not this one:
1. `ae077860c` (virtio-blk completion deadlock): 19,327 ms -> 7,782 ms worst stall.
2. `dad77b7f` + `746e5bcd` (skip the AS-wide vmas_mutex write lock on non-COW
   faults): verified built and armed (cow_peek_enabled in loader.elf,
   OSV_MMU_COW_PEEK defaults ON) - yet the probe still recorded 11,690 ms and
   10,989 ms.

That the stall did not shrink, and may have grown, is consistent: removing the
fault-path lock lets more faults reach the flush path faster, so the global
flush mutex becomes the binding constraint.

## What this is NOT

Not a bug in the sense of incorrect code - `flush_tlb_all()` is correct and its
comment explains why it must block. It is a SCALABILITY limit: a single global
serialization point on a path that a 32-backend database exercises constantly.

## Candidate directions (none validated yet - do not claim any of these work)

1. Avoid the broadcast where possible: many COW faults install a PTE only in the
   faulting address space, so a LOCAL flush suffices. The base already does local
   flushes on the nested (exception_depth >= 2) path; the question is how often the
   non-nested path takes a global flush it does not need.
2. Batch/coalesce broadcasts: multiple pending flushes could share one IPI round if
   they are already queued on the mutex.
3. Allow concurrent broadcasts: the single `tlb_flush_waiter` is what forces strict
   serialization; a per-CPU or per-request waiter would let independent flushes
   proceed in parallel.
4. Range-based rather than all-CPU invalidation where the mapping is known to be
   private to one AS.

Any of these is real kernel work and must be measured against the same gate
(0 probe samples >= 5s at VU32 in baseline A) before being believed.

## Status of the tail-latency investigation

Three independent causes, all now identified:
- completion-side virtio-blk deadlock - FIXED (ae077860c, upstream)
- fault-side AS-wide vmas_mutex write lock - FIXED (dad77b7f + 746e5bcd, ours)
- global TLB-flush serialization - IDENTIFIED, not fixed

The gate remains FAILED. Worst stall progression: ~19.3 s -> ~7.8 s -> ~11 s
(the last is within noise of ~7.8 s given only 1-2 samples >= 5 s per run; no
regression should be claimed without a controlled repeat).
