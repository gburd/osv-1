# Campaign 4: two master-eligible PRs, the fork fix confirmed cross-ISA, no NOPM sweep

2026-09-09, agent 1b02c3e6. Both boxes terminated, **0 orphans**. ~5.6h.

## THE HEADLINE OUTCOME: the first non-fork-gated upstream PRs of the whole programme

    #1502  vfs: fix AB-BA deadlock between dentry_hash_lock and the vnode lock   base=master, MERGEABLE
    #1503  vfs: split the global dentry hash lock into per-bucket locks           base=master, MERGEABLE

Verified: 0 `CONF_fork` references, compile clean at `conf_fork=0`, all commits `%G?`=G, leak-scanned.
Everything else this programme has produced was fork-gated and confined to #1456 comments.

## My mechanism was wrong for the third time on this bug; the agent's is right
Falsified by inspection: `dentry_lookup` allocates **nothing** under the lock; `dentry_alloc`'s
`calloc`/`strdup`/`vn_add_name` are all **before** the lock; `dentry_move`'s `strdup`-under-lock is
real but reachable only from `sys_rename`, not the `sys_open` path in the trace.

**The real defect is an AB-BA inversion** (`vn_lock -> dentry_hash_lock` in `namei`, versus
`dentry_hash_lock -> vn_lock` in `drele`), and it explains the datum mine never could: two threads each
holding what the other needs leaves **nothing runnable**, matching "all 32 vCPUs halted in `do_idle`
with an empty wakeup mask". The `owner` sleeping in `l1::alloc_page` was a thread that held the lock and
then slept in an **unrelated** allocation - the stack showed where it slept, not why the system stalled.

### Proof with teeth, on a boot path
`ASSERT(!vfs_dentry_hash_lock_held())` in `vn_lock()` under `DEBUG_VFS`. Unfixed:

    vn_lock+168 <- vn_del_name+17 <- drele+103 <- vfs_file::close()+87 <- fdrop+80
      <- close+23 <- vfs_init+182

Fires during `vfs_init` on the ordinary `close()` path, so the cycle is built **constantly**, not
rarely. Fixed, same test and config: silent, `2880 ops, 0 failures, OK`. 12/12 regression tests pass
(`tst-vfs`, `tst-symlink` 141/0, `tst-remove` 38/0, `tst-pipe` 87/0, the three fork tests, ...);
`tst-openat` fails **identically on unfixed code**, i.e. pre-existing.

### The honest negative, kept in the PR
Its concurrency harness (**172,800 ops**, 48 threads, TCG) **passes on unfixed code**. The hang was not
reproduced on a cheap box - closing the cycle needs real parallelism and a same-vnode collision. Stated
in #1502 so no reviewer concludes the bug is fictional.

## The fork fix carries to x86, and I now know exactly why it is only 2.5x there

Same-binary A/B, interleaved on -> off -> on -> off, x86 metal:

    OSV_FORK_RANGE_BS on   median  78 ms  (p99 122)   n=60
                    off    median 194 ms  (p99 202)   n=45
                     on    median  78 ms  (p99  80)   n=45
                    off    median 196 ms  (p99 204)   n=40

psql spawn floor 4 ms, so ~74 ms is server-side. **2.5x, reproduced.**

**And the agent's premise correction, which I verified, is the key insight:**

    branch                          OSV_FORK_RANGE_BS   OSV_FORK_LARGE_SHARE
    wip/pg-v26-faultfix-repinned            0                   0
    wip/fork-clone-scan (x86 ingredient)    2                   0     <- HALF the fix
    wip/forkroot-arm-base (aarch64)         2                   2     <- BOTH halves

**The x86 base has only half the fork fix.** The 2 MB large-page sharing that took aarch64 from 42.6 ms
to 3.98 ms exists **only on the aarch64 branch**. So:

    aarch64, both halves : 117.3 -> 3.98 ms   (29.5x)   vs Linux 4.0-4.3  => AT PARITY
    x86, RANGE_BS only   : 196   -> 78 ms     (2.5x)    vs Linux 4.0-4.3  => still 18.8x behind

**The remaining x86 connect gap has a known, already-written, already-measured fix.** And the commit is
**arch-neutral** (zero `__aarch64__`/`__x86_64__` guards in its `core/mmu.cc` change), so porting it is
mechanical rather than research. That is the single highest-value next action.

## Not reached, stated plainly
**No NOPM sweep at all** - no HammerDB, no VU levels, no 3-repeat cells, no NEWORD percentiles, no
aarch64 arm. ~2h lost to substrate: AL2023 qemu lacks a `user` netdev, `libstdc++.a`, perl `FindBin`,
absent musl-gcc, and **a submodule-update that silently reverted `apps` to the upstream pin and
re-armed the shadowed-build trap**. `--norandom` also breaks PG ("could not generate random cancel
key") - do not pass it. My `seed_copy` ordering diagnosis was confirmed correct: `/zfs.so mount` must
precede `seed_copy`.

At VU32 only 1 backend was ever active with %util 0.00, but the agent **could not distinguish guest
serialization from its own psql-per-client harness and therefore drew no conclusion.** So the
per-bucket arm's throughput effect remains **unmeasured**, exactly as #1503 states.

## Where the north star stands
- **Connect latency**: solved on aarch64 (at Linux parity), 2.5x better on x86 with a known remaining
  fix worth ~10x more.
- **Throughput**: still 4.9x behind at VU8 and 21.6x at VU64 on the older x86 base, and **the two new
  VFS fixes have not been throughput-measured at all.**
- **Upstreaming**: 50 open PRs, 28 merged, and for the first time two of them are master-eligible VFS
  correctness fixes rather than fork-gated notes.
