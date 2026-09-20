# ZIL hires-cv A/B: NULL. The fix is correct but does not move throughput. The lead is elsewhere.

Agent fb4ad66f, 2026-09-11, lava. Both boxes TERMINATED, 0 orphans, 0 volumes confirmed.

## The measurement (one variable: OSV_ZFS_HIRES_CV, same image/pool/dataset/GUCs)
    VU    ON median   OFF median   delta%   ON/OFF
    8       48,758      47,144      +3.4%    1.034
    32      37,012      36,957      +0.1%    1.001
    64      33,864      32,910      +2.9%    1.029
Every delta <= the 3.0-3.6% run-to-run spread. **ON = OFF.** Console proved the flag bound with
DIFFERENT values per arm (ON "=1 (set)", OFF "=0 (set)"), so the A/B is valid, not a dropped flag.

## What this closes
ZIL commit-batch coalescing is **not** the throughput lever for this TPROC-C workload. PR #1505 stands
on **correctness** (honouring a requested sub-ms deadline is right) but carries **no measured throughput
benefit** - the comment I already posted on #1505 anticipated exactly this, so it needs no retraction.

Also closes, retroactively: the August "synchronous_commit on/off = 6.3x" finding cannot have been ZIL
batching, because with batching toggled off here NOPM did not fall. Whatever the 6.3x was, it was not
this. (Candidate: that measurement was on the bsd_zfs engine or a different base; do not trust it.)

## The real lead, and it is specific and reproducible
At VU32, BOTH arms:
    NVMe %util  ~10-15%      w_await 0.13ms   aqu-sz ~0.2-0.3   ~83-98 MB/s
    guest CPU   ~13-15% of 32 vCPU (~400-485% of one core against a 3200 ceiling)
**Device idle AND CPU idle while throughput is pinned.** Nothing is saturated - not the disk, not the
CPU, not the ZIL timer. Backends are waiting on a serialization point, not on hardware. This is the SAME
idle-device/idle-CPU signature a2abench7 flagged and the same shape as the wedge backtrace (1,138
threads, 184 backends behind dentry_hash_lock, 32 vCPUs halted with an empty wakeup mask).

Second-order evidence: after sustained VU64 load the **checkpointer stopped converging** - a `checkpoint
starting: time` that never completed within 900s while `select 1` still answered. A checkpointer that
cannot make progress while the device is 85% idle is a scheduling/wakeup or lock-ordering problem, not
an IO-bandwidth problem.

## What the next experiment MUST capture that this one did not
This run instrumented iostat %util and qemu CPU but **NOT pg_stat_activity wait events**, which is the
actual discriminator. Do not repeat that. The next run must, at VU32 and the top VU, sample:
  - `pg_stat_activity`: wait_event_type / wait_event histogram over the timed window (NOT just
    state='active' - that means "not on a registered wait event", not "on CPU"; a prior CPU-bound
    verdict was wrong by 60x on exactly this confusion).
  - `pg_stat_activity` count in LWLock:* vs IO:* vs Lock:* vs Client:* buckets.
  - if possible an OSv-side thread state histogram (how many threads [halted] vs runnable) to correlate
    with the wedge backtrace.

## Candidate levers now ranked (device-idle + CPU-idle => a serialization point)
1. **dentry_hash_lock / VFS single lock** - PR #1503 (per-chain locks) EXISTS and its throughput effect
   is UNMEASURED. This is the top candidate and the A/B is already built (OSV_VFS_DENTRY_PERBUCKET).
   Same-binary A/B, same methodology as this run.
2. **WAL insert/write serialization** inside PG that OSv's condvar/wakeup latency amplifies - would show
   as LWLock:WALWrite/WALInsert in the wait histogram.
3. **The checkpointer wakeup/progress stall** - correlate the never-completing checkpoint with OSv
   thread states.
4. ZFS write amplification - now LOWER priority since device is 85% idle (amplification would raise
   %util, and it did not).

## Discipline the agent honoured (recorded, not massaged)
- VOIDED OFF-VU8-r1 = 115,988 (false quiesce: one fast checkpoint right after crash-recovery drained a
  backlog, 2.4x inflated - same failure as a2abench7's 80,417). Then HARDENED quiesce to require TWO
  consecutive sub-1s checkpoints. This is the quiesce protocol going forward.
- VU64-OFF r2/r2b stalled (checkpointer non-convergence); kept the 1 properly-quiesced point, disclosed.
- An 8-min PG crash-recovery from a 2-QEMU-on-one-disk slip; ZFS checksums clean, replayed to 19 GB
  intact - a real durability datapoint in passing.
