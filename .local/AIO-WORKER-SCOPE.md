# PG18 io_method=worker on OSv: the blocking comment may be STALE

2026-09-08, agent b9e2aea5 (box i-0c3fa3495616ae456, m5d.metal, Owner=agent-aio).

## The finding, from source reading, pending hardware proof

**PG 18's `io_method=worker` needs NO kernel AIO.** `method_worker.c` is pure userspace:
shared-memory submission queue + LWLock + Latch (`SetLatch` -> `kill(pid, SIGURG)` cross-process)
+ forked auxiliary "IO worker" processes calling plain `pg_preadv`/`pg_pwritev`. Every one of those
primitives is already exercised by the PG-on-OSv build today.

Verified by me:
- The blocking comment **does** conflate two unrelated mechanisms. `apps/postgres18-musl/build.sh`
  says "**OSv's io_uring/worker AIO path is incomplete**", and the conf line says "OSv AIO path
  incomplete; use sync I/O". One sentence covering `io_uring` and `worker` together.
- `libc/signal.cc` has **13** `as_for_pid`/`SIGURG` references (explicit cross-AS signal delivery),
  and `fs/vfs/main.cc` has `preadv`/`pwritev`.

So **the caveat that has forced every benchmark in this project to `io_method=sync` on both sides
may be removable with zero code.** `io_uring` by contrast needs `--with-liburing` at PG configure
time (which changes the **identity tuple** and would have to be matched across every arm), liburing
in the image, and OSv io_uring syscalls - correctly deprioritised.

## The specific risk I flagged
`io_method=worker`'s latch wakeup is **exactly** the code path with an open soundness question on
#1475. `libc/signal.cc:548` states in its own comment that "kill() spawns a NEW detached thread and
`set_address_space()`es it into" the target AS, with `target_as = osv::fork::as_for_pid(pid)` at
`:559`/`:581`. So `worker` will drive **cross-AS thread injection at a far higher rate than anything
tested so far** - every IO completion latch, not just occasional backend wakeups.

Asked for:
1. Expect breakage THERE if anywhere, and capture it (corruption, `chunk_magic`, or a fault in a
   signal/latch path rather than an I/O path) rather than working around it.
2. **Report the SIGURG/latch rate**, even to an order of magnitude. "worker works and drove N latch
   wakeups/sec through the cross-AS injection path" is independent evidence about that path's
   robustness, and if it holds at high rate it **partially answers the #1475 concern empirically**.
3. Set `io_workers` explicitly and test more than one value - working at 3 but failing at 8 is a
   scaling limit worth knowing and is cheap to find.

## Deliverables if it just works
(a) proof: `SHOW io_method` from an EXTERNAL client plus a completed workload;
(b) the **sync-vs-worker delta on OSv**, several concurrency levels, >=3 repeats, spread flagged;
(c) **a patch to `build.sh` correcting the comment and the conf default** - small, and it removes a
standing caveat from every future comparison.

## Measurement caution issued
Do NOT re-run the benchmarks with `worker` on OSv only. The current comparison is matched at
`sync` deliberately; switching one side reintroduces exactly the confound we removed. What is wanted
is the **OSv-internal delta**, so we can decide whether to re-baseline BOTH sides at `worker`.

## CONFIRMED 2026-09-09: `io_method=worker` ALREADY WORKS. Zero code needed.

Proof from an EXTERNAL client (host container psql -> guest 192.168.100.2:5432 over tap/bridge):

    version:    PostgreSQL 18.6 on x86_64-pc-linux-musl, gcc 13.3.1
    io_method:  worker
    io_workers: 3

PG started clean, **3 IO worker processes forked**, "database system is ready to accept
connections", no faults. PGDATA on ZFS dataset `osvpg/pgdata` (ashift=12, recordsize=8k) on a raw
virtio-blk disk, **not ramfs**.

Identity: osv `d74b69c6` (= `wip/fork-clone-scan` `65279b93` + cherry-picked apps pin `124caf42`),
apps `b38b99cd`, PG `REL_18_STABLE` 18.6, **configure line UNCHANGED**.

**So the comment at `build.sh:132`/`:164` that has forced EVERY OSv-vs-Linux comparison in this
project to `io_method=sync` on both sides is simply stale**, and it conflated `worker` (pure
userspace: shm queue + LWLock + Latch + forked workers calling `pg_preadv`/`pg_pwritev`) with
`io_uring` (which really does need `--with-liburing`, liburing in the image, and OSv io_uring
syscalls).

## The detail that makes the experiment stronger than I designed
**`io_method` is `PGC_POSTMASTER`, so both arms come from ONE build via `-c io_method=...` and the
identity tuple is IDENTICAL across arms.** No configure divergence, no asymmetry to caveat, and the
delta is attributable to the setting alone - the same "same binary, one variable" property as the
`OSV_FORK_RANGE_BS` A/B. It also removes the io_uring configure-change concern from the worker
deliverable entirely.

## The Makefile shadowing trap, verified
    Makefile:1  .PHONY: module
            :2  module: build
            :7  build:            <- a REAL target
            :10 .PHONY: clean
No `.PHONY: build`, so the real `build/` directory shadows the target. Result: a **10 MB
PostgreSQL-free image reporting BUILD_RC=0**. It has now bitten at least two agents. One-line fix
(`.PHONY: module build`) to be filed as its own small PR **against `gburd/osv-apps`**, since that
Makefile lives in the apps tree, not cloudius-systems/osv.

Also: fedora:39 needs `perl-FindBin` or PG's `generated-headers` step dies.

## Instructions issued
- **Interleave the sync/worker arms** (each switch costs a postmaster restart since the GUC is
  PGC_POSTMASTER), and state whether the pool was re-imported or re-seeded between arms - a
  cold-vs-warm ARC difference across arms would swamp the effect being measured.
- **Correct the comment, but do NOT flip the benchmark default to `worker` unilaterally**: the
  matched-`sync` comparison is deliberate and switching only OSv reintroduces the confound.
- **Report the SIGURG/latch rate**: `worker` drives cross-AS thread injection through `as_for_pid` at
  every IO completion, and that path has an open soundness question on #1475. Surviving a high latch
  rate would be empirical evidence about a path we have only reasoned about.
- **Calibration given**: the real gap is 5.3x at VU8 widening to 22x at high concurrency, and Linux
  scales while OSv does not. A few percent from `worker` is a true but small lever; **if `worker`
  changes the SHAPE (helps more at high VU) that is far more interesting than a flat gain.**

## Outcome: the win is banked, the A/B was never run, the box leaked and was reclaimed

The agent exhausted its context mid-task (its final message reads "Now build the interleaved A/B
harness"), so:

**Banked, and this is the durable value:**
- `io_method=worker` **works on OSv**, proven externally: `io_method: worker`, `io_workers: 3`,
  `PostgreSQL 18.6 on x86_64-pc-linux-musl`, PGDATA on ZFS not ramfs, no faults.
- **PR #73 updated** on `gburd/osv-apps` (`b38b99c..5cb1903`, G-signed, leak-clean) with two one-line
  fixes: `.PHONY: module build` for the shadowed target, and the corrected `io_method` comment
  explaining that `worker` works, `io_uring` is the incomplete one and needs `--with-liburing`, and
  that `io_method` is `PGC_POSTMASTER` so one build selects any method at run time.
- Comment posted: osv-apps#73 issuecomment-5604505482.

**NOT done: the sync-vs-worker delta.** No numbers were captured, so "what is finishing OSv's AIO path
worth?" remains unanswered. Also unmeasured: the SIGURG/latch rate and `io_workers` scaling.

**Box leak:** `i-0c3fa3495616ae456` (m5d.metal) was left running with no agent driving it. I salvaged
the `.PHONY` diff off the box **before** terminating it, then reclaimed it. That is the second leaked
box today from context exhaustion, and both times the salvage-then-reclaim order mattered.

## io_uring is viable, which changes the plan
User direction is to benchmark with io_uring rather than worker. Checked feasibility on
`upstream/master`, and it is better than expected:
- `core/io_uring.cc` **is on master**, with `io_uring_setup` wired through `linux.cc`.
- **Every opcode PG 18 needs is implemented**: NOP, READV, WRITEV, READ, WRITE, READ_FIXED,
  WRITE_FIXED, FSYNC, POLL_ADD.
Remaining work is `--with-liburing` at PG configure time plus liburing in the image. **That changes
the identity tuple, so BOTH arms must move together** or the confound this campaign spent a day
eliminating comes straight back.
