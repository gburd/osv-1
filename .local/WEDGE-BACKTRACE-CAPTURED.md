# The wedge backtrace, captured at last: all 32 vCPUs idle, 1,138 threads waiting, zero runnable

2026-09-09, agent 7d0737f3 Task B. **Guest was still live and wedged when it attached - it did not
pkill.** Detector was three consecutive real-query failures with `TCP_ACCEPT=YES` throughout, which is
exactly why a TCP probe could not have found it.

## The state

    1,172 OSv threads: 1,138 WAITING, 32 "running" - and all 32 running are the IDLE threads.
    All 32 vCPUs [halted] in sched::cpu::do_idle at core/sched.cc:610, inside
      handle_incoming_wakeups() with an EMPTY wakeup mask.
    qemu at 26.7% of one core.

**Zero runnable work exists.** This is a lost wakeup, not a slow path and not CPU starvation.

## Blocked-thread histogram (1,138 waiters)

     735  bsd/porting/synch.cc:102     synch_port::_msleep  (ZFS/BSD sleep)
     184  arch/x64/arch-switch.hh:175  PostgreSQL backends
      32  rcu.cc:185 / percpu-worker.cc:92 / mempool.cc:1648 / async.cc:190  (normal housekeeping)
      22  core/condvar.cc:62
       2  drivers/virtio-blk.cc:389    BOTH virtio-blk completion threads idle in req_done()

The 735 include 64 `z_unlinked_drain`, 64 `dp_zil_clean_taskq`, and every `z_wr_iss`/`z_wr_int`/
`z_rd_iss` writer: **the entire ZFS write pipeline is asleep with nothing queued.**

## The visible victim: one global VFS lock

A PostgreSQL backend blocked on:

    #7  lockfree::mutex::lock (this=0x40bf5940 <dentry_hash_lock>)  core/lfmutex.cc:129
    #9  dentry_lookup (path="/pg/postmaster.pid")                   fs/vfs/vfs_dentry.cc:116
    #11 sys_open (path="/data/pg/postmaster.pid")                   fs/vfs/vfs_syscalls.cc:169

**Verified in source: `dentry_hash_lock` is a SINGLE global mutex** (`vfs_dentry.cc:50`) guarding
`dentry_hash_table[DENTRY_BUCKETS]` with **32 buckets and no per-bucket locking** (`:48`, `:66`),
acquired at **14 sites**. Every path lookup in the system serialises on it, and **184 PostgreSQL
backends are parked behind it.**

## My correction to the obvious reading, which changes the fix
I checked the two hot paths and **neither blocks while holding the lock**:
- `dentry_lookup` (`:116`) walks the bucket and releases before returning.
- `drele` takes the lock, decrements, `LIST_REMOVE`, `vn_del_name`, then **unlocks BEFORE** `vrele`
  and `free`.

So this is probably **not** a hold-and-block deadlock, and `dentry_hash_lock` is the **visible victim
rather than the cause**. That fits the evidence better: in a classic deadlock the owner is somewhere,
blocked on something identifiable; here every CPU is halted with an empty wakeup mask and nothing is
runnable at all.

**The most promising lead is the pairing the agent spotted:** the entire ZFS write pipeline asleep with
nothing queued, while **both virtio-blk completion threads sit idle in `req_done()`**. If ZFS is
waiting on I/O that virtio-blk considers complete, that is a **completion-path lost wakeup** and it
would be the actual root cause. Asked for: the `dentry_hash_lock` owner (null or unrelated => lost
wakeup on the mutex; blocked in ZFS => the lock IS held across a ZFS op somewhere I have not found),
one `z_wr_iss`/`txg_sync` stack with what it sleeps on, and the run queues / wakeup masks.

## Two findings to report separately regardless
1. **The global `dentry_hash_lock` is a scalability defect in its own right**, independent of this
   hang: 184 backends behind one VFS mutex is a plausible contributor to the 22x throughput gap at
   high concurrency, and **the 32 buckets already exist**, so per-bucket locking is a small, obvious
   change.
2. **No OOM and no elf fault in this run** - a second independent non-recurrence after the other
   agent's ~40 boots, strengthening the case that `866bc8b6a` already fixed the allocator abort.

Firecracker is now explicitly optional; this trace is worth more.

# ROOT CAUSE ESTABLISHED: dentry_hash_lock is held across a BLOCKING allocation

**My "lost wakeup, the lock is the victim not the cause" reading was WRONG.** The agent had already
extracted the mutex owner, and the owner is neither null nor blocked on something unrelated: it is
blocked **inside the page allocator while holding the global VFS lock.**

    mutex: {count = 8, depth = 1, owner = 0x40032f208040, sequence = 92}
    owner resolves to a LIVE thread: 220584 (>/usr/bin/postg, cpu0, waiting)
      -> which is what rules out the lost-wakeup hypothesis outright

    owner stack:
      #0  sched::thread::switch_to            arch/x64/arch-switch.hh:175
      #3  memory::page_pool::l1::alloc_page   core/mempool.cc:1464
      #4  memory::untracked_alloc_page        core/mempool.cc:2015
      #5  memory::pool::add_page              core/mempool.cc:305

## The mechanism, now fully established

    PG backend -> sys_open("/data/pg/postmaster.pid") -> namei -> dentry_lookup
      -> takes the GLOBAL dentry_hash_lock
      -> allocates under the lock -> l1::alloc_page -> L1 pool empty -> l1::refill
      -> BLOCKS waiting on the L2 page batch, still holding the global VFS lock
    => 8 mutex waiters, 184 PG backends parked, all 32 vCPUs halted, 1,138 waiting,
       zero runnable. The whole system stops rather than slowing.

## Why my source reading missed it, and the lesson
I checked `dentry_lookup` and `drele` for explicit blocking calls (`vput`/`vrele`), found none, and
concluded the lock is never held across a sleep. **The sleep is inside the allocator, reached
implicitly from any allocation made under the lock.** Verified after the fact:

    core/mempool.cc:1464  alloc_page() { while (!(ret = alloc_page_local())) { refill(); } }
    core/mempool.cc:1611  l1::refill() -> global_l2.alloc_page_batch()
    core/mempool.cc:1624  its OWN comment: "while we waited for the page batch"

**Standing lesson: reading a function for blocking calls only proves it does not block EXPLICITLY.
The allocator is a sleeping site reachable from any allocation, so the pattern to grep for is "holds
a lock across a malloc", not "holds a lock across a named blocking call."** Second time today an
agent corrected a source-level claim I made after reading the code.

## Two separable, independently upstreamable findings
1. **The bug**: `dentry_hash_lock` is held across an allocation that can block. Narrow fix is to not
   allocate under the lock (pre-allocate before acquiring, or drop and retry). Asked for the precise
   allocation site in `vfs_dentry.cc` that reaches `pool::add_page`, since naming the caller matters
   for the fix.
2. **Independent scalability defect**: the lock is global across 32 buckets that already exist, so
   per-bucket locking is a small change - worth doing even after (1), and a plausible contributor to
   the 22x gap at high concurrency.

## The open question that decides whether fix (1) is sufficient
**Is the L2 fill thread (`page_pool_l2`) itself blocked, and on what?** If L2 waits on something that
needs the VFS lock, or needs memory only reclaim can free, then fixing the allocation-under-lock
removes this deadlock but leaves a memory-exhaustion stall underneath. With 735 threads in
`synch_port::_msleep` (the whole ZFS write pipeline, nothing queued) and both virtio-blk completion
threads idle, the question is whether the system was genuinely out of free pages or whether pages
existed and only the refill path was stuck. `memory::stats::free()` plus the L2 stack answers it.

## L2 answered: 27 GiB FREE. Not memory exhaustion. Fix (1) is sufficient.

Measured live from the wedged guest:

    global_l2._nr = 0                        L2 page-batch stack EMPTY
    Free Memory: 28,920,045,568 (42.08%)     26.9 GiB genuinely free
    Total Memory: 68,718,926,848  Mmap: 18,217,312,256 (26.51%)
    page_pool_l2 thread: WAITING at core/mempool.cc:1763 in l2::fill_thread()

**27 GiB free while the batch stack sits empty** is the discriminator I asked for. The system was NOT
out of memory; only the refill path was stuck. So removing the allocation-under-lock removes the
deadlock **without leaving a memory-exhaustion stall underneath it.** Measured, not reasoned.

### My refinement to the mechanism (makes it stronger, not weaker)
I traced the consumer path. `l2::alloc_page_batch()` at `core/mempool.cc:1484` is:

    while (!(pb = try_alloc_page_batch())) {
        WITH_LOCK(migration_lock) { DROP_LOCK(preempt_lock) { refill(); } }
    }

so the consumer **calls `refill()` itself** rather than waiting on the `page_pool_l2` thread, and
`l2::fill_thread` waits on a watermark predicate (`nr < _watermark_lo || nr > _watermark_hi`).
**Therefore the parked fill thread is a symptom, not the blocking dependency** - the blocked backend
is sleeping inside L2's own `refill()`. Correct phrasing for the report: "the backend blocks inside the
allocator's refill path with the global VFS lock held, while 27 GiB is free", **not** "blocks waiting
for the L2 fill thread". Same conclusion, accurate mechanism, and it forecloses the obvious reviewer
objection ("why didn't the fill thread just run?").

### An honest limit, correctly stated rather than guessed
The exact `vfs_dentry.cc` line that reaches `pool::add_page` is **not recoverable**: frame #2 is
`0x00002000001fffd0 in ?? ()` and the unwind dies at "Cannot access memory at address
0xfffffffffffff6c8", because the allocation happens on a **lazily-mapped stack region**. The agent
declined to guess.

What IS proven and is sufficient for a fix: the owner held the lock (`owner=0x40032f208040`,
`depth=1`, `count=8`), that thread's live stack is dentry-then-allocator, and 27 GiB was free. A
maintainer can locate the call site in `dentry_lookup`/`dentry_alloc` by inspection far more cheaply
than from a truncated unwind. Inspection candidates listed as candidates, labelled as such.

## Final disposition
Two separable, independently upstreamable findings, both to #1456 (needs `conf_fork=1` to reproduce at
this scale):
- **(a) the deadlock**: `dentry_hash_lock` held across a blocking allocation, with owner/stack/
  free-memory evidence.
- **(b) the scalability defect**: one global lock for 32 buckets that already exist. Independent of
  (a), small to fix, and the leading candidate for why OSv converts concurrency into queueing while
  Linux converts it into throughput.
Firecracker explicitly not reached. Corrected Linux baseline is the campaign headline and must not be
buried under the wedge finding.

# MECHANISM CORRECTED AGAIN (2026-09-09): it is an AB-BA LOCK INVERSION, not allocation-under-lock

Agent 1b02c3e6 refuted my mechanism by code inspection **before spending a single box**, and proposed
a different defect in the same file that fits the evidence better. I verified all four claims.

## What I had wrong
1. **"`dentry_lookup` takes the lock then allocates" - FALSE.** `fs/vfs/vfs_dentry.cc:113-125` does
   exactly `LIST_FOREACH` + `strncmp` + `d_refcnt++` between lock and unlock. **Zero allocation.**
2. **"`dentry_alloc`'s insert path allocates under the lock" - FALSE.** `calloc` (`:80`), `strdup`
   (`:91`) and `vn_add_name` (`:98`) are all **strictly before** `mutex_lock` at `:100`, which spans
   exactly one `LIST_INSERT_HEAD`.
3. There IS one allocation under the lock - `dentry_move` (`:162-176`) does `strdup` inside
   `WITH_LOCK(dentry_hash_lock)` - but it is reached only from `sys_rename`, **not** from the
   `sys_open`/`namei`/`dentry_lookup` path in the trace. A real latent defect, not this bug.

## The actual defect: AB-BA inversion between dentry_hash_lock and vn_lock

    Path A (namei):  vfs_lookup.cc:178  vn_lock(dvp); dp = dentry_lookup(mp, node);
                     vfs_lookup.cc:284  vn_lock(dvp); dp = dentry_lookup(mp, node.get());
                     => vn_lock -> dentry_hash_lock
    Path B (drele):  vfs_dentry.cc:221  mutex_lock(&dentry_hash_lock);
                     vfs_dentry.cc:227  vn_del_name(dp->d_vnode, dp);
                     vfs_vnode.cc:531   vn_del_name() { vn_lock(vp); ... }
                     => dentry_hash_lock -> vn_lock

Both directions verified by me at four sites. Reachable on the same vnode whenever the dentry being
released is a directory, and `namei` itself does `drele(ddp)` on directory dentries - **so it is not
theoretical.**

## Why it fits the evidence better, on the point I could not explain
With a sleeping allocation you would expect eventual progress - **26.9 GiB was free**. A true AB-BA
inversion means **nobody is runnable, ever**, which is exactly what was observed: all 32 vCPUs
`[halted]` in `do_idle` with an **empty wakeup mask** and zero runnable threads. **My mechanism never
explained the empty wakeup mask. This one does.**

And the owner evidence now reads differently: I treated `owner` blocked in `l1::alloc_page` as proof of
allocation-under-lock. It is equally consistent with that thread having taken `dentry_hash_lock` and
then blocking on a genuinely **unrelated** allocation, while a *different* thread holds `vn_lock` and
waits for the dentry lock. **The stack proves where the owner sleeps, not that the sleep causes the
system-wide stall.** That is the same class of error as reading `state='active'` as "on CPU".

## Fix requirements issued
- **Establish and state an explicit lock order** ("vnode lock before dentry_hash_lock, never the
  reverse") and make `drele`/`vn_del_name` conform. Hazard flagged: dropping the lock mid-`drele`
  reopens the refcount race, so the removal must stay atomic (re-check after reacquire, or unlink
  first and call `vn_del_name` outside the critical section).
- **Fix `dentry_move`'s `strdup`-under-lock as a separate commit** - a real latent defect on
  `sys_rename`, trivially fixed by hoisting.
- **Per-bucket locking stays its own commit**, measured separately, and **must preserve the new
  ordering** - a per-bucket lock still inverts against `vn_lock`, so the ordering fix comes first.
- **Prove the ordering, do not assert it**: a lock-order assertion that fires on the unfixed code and
  is silent on the fixed code, held to the same "prove the check has teeth" standard as the rest of
  the campaign.

## This raises the stakes on eligibility
`vfs_dentry.cc`, `vfs_lookup.cc` and `vfs_vnode.cc` all exist on `upstream/master`, and an AB-BA
inversion is a defect **with or without `conf_fork=1`** - fork merely supplies enough concurrent
`open()`/`drele()` traffic to hit it. Asked whether it reproduces without fork, because if it does this
is a genuine standalone upstream PR and **the first non-fork-gated fix of the entire campaign.**
