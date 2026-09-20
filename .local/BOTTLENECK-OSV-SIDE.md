# The bottleneck is OSv-side, below the syscall boundary, invisible to PG. Measured, triangulated.

Agent 2da08127, dentry per-chain A/B, VU64, PERCHAIN arm. The single most localising measurement so far.

## The triangulation (all three legs measured, not inferred)
    ~90% of active PG backends: wait_event = NULL
    NVMe %util:  13.5%   (host iostat)
    qemu CPU:    ~12% of 32 vCPU  (host counter)

Three independent instruments, three "not here":
  - NOT on a PG registered wait event (so NOT PG LWLock/Lock/IO/Client contention).
    LWLock:* was tiny: 313 obs @VU32, 670 @VU64, all WALWrite.
  - NOT on the CPU: 12% of 32 vCPU, confirmed by the HOST counter (this is what makes it
    provable - the NULL wait_event alone could not distinguish "on CPU" from "stalled",
    which is the exact 60x-wrong trap from earlier in the campaign).
  - NOT on the device: 13.5% util.

## The conclusion
The serialization is **OSv-side, below the syscall boundary**. PG backends are blocked in a syscall
that OSv is not completing - a kernel mutex/condvar or a wakeup that never arrives. PG cannot label it
because the block is beneath PG's visibility. This is the same shape as the wedge backtrace: threads
halted with an empty wakeup mask.

## What this predicts for the dentry A/B (running now)
If the block is in wakeup/scheduling rather than in the dentry lock itself, PERCHAIN vs GLOBAL will be
ANOTHER null - splitting a lock does not help backends that are stalled waiting to be woken, not
contending on that lock. A second null COMBINED with this histogram would **rule the dentry lock out**
and point at the scheduler/wakeup path. Steered the agent to grab an OSv-side thread-state snapshot
under load (REST API / gdb thread-apply-all-bt / or a frozen-state_change count) to localise it before
the boxes die.

## The named next targets (device-idle + CPU-idle + NULL-wait => wakeup/scheduling)
1. **OSv scheduler wakeup / IPI path.** The wedge backtrace showed 32 vCPUs [halted] in do_idle with an
   EMPTY wakeup mask and global_l2._nr=0 - a stuck refill, threads not being woken. Prime suspect.
2. **condvar/wakeup in the virtio-blk or ZIL completion path** - a completion that wakes one waiter but
   not the batch, so throughput is gated by wakeup latency not IO bandwidth (device is 87% idle).
3. **The checkpointer non-convergence** (checkpoint starting: time never completes while select 1
   works) is likely the SAME stall - a background worker that cannot be scheduled/woken.
4. Dentry lock - being A/B tested now; likely to be ruled OUT by a null.

## Standing note
This is why the ZIL and (probably) dentry A/Bs both return null: they are fixes to the wrong layer. The
throughput ceiling is not in any single PG lock or ZFS timer; it is in how OSv wakes and schedules the
hundreds of threads a 200-warehouse TPROC-C run spawns. That is a scheduler investigation, and it is a
generic OSv improvement (G2), not a PG-specific one - which is the right kind of target.
