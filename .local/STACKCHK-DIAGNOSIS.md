# __stack_chk_fail after 1-5 forks: diagnosis before dispatch

2026-09-10. Agent 6bc0852a dispatched with a concrete hypothesis rather than a hunting brief, because
I found a plausible mechanism by source reading first.

## The signature, from the previous agent's elimination work
Crash tracks **cumulative fork count**, and is independent of:
- the fork perf ports (both A/B arms crash identically, 6/6 boots)
- query work (500k inserts + full update + 71k deletes + VACUUM + CHECKPOINT on one held connection,
  zero crashes - **the next NEW connection killed it**)
- concurrency (8/8, 16/16, 32/32, **96/96** simultaneous connections all fine from a fresh boot)
- `shared_buffers` (16GB/1GB/128MB -> 2/4/2 forks) and kernel stack depth (4x -> 4 forks only)

## My hypothesis: all forked children SHARE one musl pthread struct, including the canary slot

Chain of evidence from source:
1. `runtime.cc:349` defines `__stack_chk_guard` as a **single global constant** (`0x12345678abcdef`),
   `:351` is the abort handler. But `Makefile:396` builds the kernel **`-fno-stack-protector`**, so a
   firing canary **must come from application code** (PostgreSQL or musl).
2. On x86-64 the canary is read from **`%fs:0x28`** - the TLS block, not that global symbol.
3. `arch/x64/arch-tls.hh:13-17`: OSv's `thread_control_block` is only **24 bytes**
   (`self`, `tls_base`, `app_tcb`), so `0x28` (40) is **past its end**. Apps must therefore be reading
   their own musl TCB, installed via `arch_prctl` and tracked as `app_tcb`.
4. `arch/x64/fork.cc:70-74` and `:117`: the child captures `parent->get_app_tcb()`, calls
   `arch::set_fsbase(parent_app_tcb)`, and `set_app_tcb(parent->get_app_tcb())`. The code comment
   itself says the child "inherits it (shared) -- the documented multi-process-glibc limit".

**So N children all point `%fs` at ONE musl pthread struct**, which holds the canary at +0x28 plus tid,
errno, cancel flags and dtv. Concurrent children writing one struct can corrupt the canary slot, and
`__stack_chk_fail` fires in whichever child next checks a function epilogue.

**That predicts a crash after a small cumulative number of forks, independent of load and of concurrent
connection count - which is exactly the observed signature.** No other hypothesis I considered explains
why 96 simultaneous connections succeed from a fresh boot while the 3rd sequential fork dies.

## Test it before fixing it (three cheap discriminators given)
1. **Print `%fs` base and `%fs:0x28` per child** with the fork index. Shared base + changing value =>
   confirmed. **Distinct bases per child => my hypothesis is WRONG**, and I asked for that to be said
   plainly.
2. **Instrument the handler** to dump `%fs:0x28`, thread id, fork index and a backtrace. Zero vs a
   pointer vs a plausible value distinguishes "TLS never initialised" from "shared and overwritten"
   from "genuine stack overflow".
3. **A 60-line C program** that forks N times and calls a stack-protected function in each child, to
   isolate this from PostgreSQL entirely. That worked for a different fork bug earlier in this campaign
   (failed in under a second, no database), and it makes the bug reproducible by a maintainer.

## Fix direction if confirmed
Give each child a **private** app TCB: it already gets a fresh OSv TLS block from its `sched::thread`
constructor, what it lacks is a private musl pthread struct. **Hazards flagged**: musl's struct contains
a self-pointer and a `dtv` pointer that need fixing up rather than blind copying, and PostgreSQL's fork
semantics require the child to see the parent's memory while per-thread state stays private. A narrower
canary-only fix may suffice, but it must say which was done and what remains shared.

## Then the benchmark
Full A2A on `wip/pg-x86-forkroot-largeshare` @ `42aeb163b` (both fork halves + elf fix + rofs/pagecache
fork-arena fixes), optionally with the `wip/dentry-lock-order` VFS fixes as a separate arm. Target:

    Linux  VU8 213,505 | VU32 510,367 | VU64 614,277 PEAK | VU96 547,813
    OSv old  VU8  43,407 -> VU96 26,047     4.9x behind widening to 21.6x

**The open question is whether the fixes change the SHAPE**, since Linux scales to VU64 and OSv peaked
at VU8. Ratios must carry their VU level.

## Capacity
104 free of a 640 quota; `m5d.metal` (96) fits **now**, but other projects churn constantly - told to
re-check immediately before launching and to do the bug work on a cheap box under TCG (a fork-count
crash needs no timing fidelity), reserving metal for the measurement with the same osv SHA.

# HYPOTHESIS REFUTED. The real bug is an OUT-OF-BOUNDS READ: the TCB is 16 bytes too short.

2026-09-10, agent 6bc0852a, from a **100-line no-database reproducer**. My shared-`app_tcb` mechanism
was wrong in its central claim.

## Why my hypothesis is dead
- `ARCH_GET_FS` returns **0 in parent AND child**, so `app_tcb == 0`. PostgreSQL is a PIE built against
  OSv's libc and **never calls `arch_prctl(ARCH_SET_FS)`**, so the inherit path at `fork.cc:73` never
  executes. **Nothing is shared.**
- `%fs:0x0` (TCB self) **differs in every child**: parent `0x50007ff69940` vs children
  `0x50007ff67940` / `0x500001445940` / `0x500001673940`. Each child already has a private OSv TLS
  block, exactly as `sched::thread`'s constructor promises.

I reached for sharing because the comment at `fork.cc:67-70` describes inherited app TCBs. **It
describes a path PostgreSQL never takes.**

## The actual defect, verified by me and worse than "uninitialised"
    arch/x64/arch-tls.hh:13-17   thread_control_block = 3 words = 24 bytes (0x18)
    GCC x86-64 canary            %fs:0x28 = 40 bytes
                                 => 16 bytes PAST the end of the struct

    arch/x64/arch-switch.hh:385  p = aligned_alloc(64, total_tls_size + sizeof(*_tcb))
                            :404 _tcb = p + total_tls_size      <- TCB at the END of the allocation
                            :405-408 initialise only self, tls_base, app_tcb

**So `%fs:0x28` reads past the end of the malloc'd buffer entirely - an out-of-bounds heap read on
every application canary check.** That explains the agent's PTE-shaped values
(`0x802000006812d065` = NX|present|user|accessed|dirty): the reads land in neighbouring allocator
memory holding page-table entries.

Measured: parent always reads 0; children read 0 for the first few forks, then garbage.

## Why this produces the exact signature (the agent's explanation, and it is the convincing part)
A fork child resumes **mid-frame on the parent's stack**, so every frame live across `fork()` carries
the **parent's** spilled canary (0), while the child re-reads its **own** uninitialised TCB+0x28 in the
epilogue. It matches only while that garbage still happens to be 0. Each fork allocates a fresh TLS
block, so the probability of landing beside nonzero memory **accumulates with cumulative fork count**
and is independent of query load, concurrency and `shared_buffers`.

And **"one held connection did 500k inserts fine, the next NEW connection died" is exactly "no forks,
then one fork."** Nothing else explains why 96 simultaneous connections succeed from a fresh boot while
the 3rd sequential fork dies.

## Fix requirements I issued
1. **Fix the allocation as well as the struct.** Growing the struct changes `sizeof(*_tcb)` so
   `aligned_alloc` follows, but **verify it**, and audit everything assuming the TCB's size or that
   `_tcb` sits at `p + total_tls_size`. **An OOB read becoming an OOB write would be far worse than the
   bug.** Also check **aarch64** - if its TCB has the same shortfall for its toolchain's offset, the x86
   fix must not silently leave it broken.
2. **Set a real canary, not zero.** Zero is what made this intermittent rather than deterministic, and a
   zero canary is worthless as mitigation. Per-thread random if available at `setup_tcb()` time, else a
   fixed nonzero constant - **and say which, noting plainly that a fixed value is a correctness fix, not
   a hardening claim.**
3. **Proof standard**: the reproducer must fail before and pass after on the same setup, and the canary
   must be shown **stable and nonzero across 200+ sequential forks**. Absence of a crash in N runs is
   weak evidence for a probabilistic bug.

## Possible SECOND master-eligible fix
`arch/x64/arch-tls.hh` and `arch/x64/arch-switch.hh` both exist on `upstream/master`, and **a TCB too
short for the compiler's canary offset is a defect with or without `conf_fork=1`** - fork merely makes
it observable by allocating many TLS blocks. Asked to test whether a **non-forking threaded program**
reads garbage at `%fs:0x28` on plain master. If so, this is a standalone upstream PR and the campaign's
second non-fork-gated fix.
