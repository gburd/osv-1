<!-- Copyright (C) 2026 Greg Burd -->
# Fork-arena concurrency checks

These are supplemental Linux host checks, not OSv guest or COW proof. No test
framework is required: Python 3, g++, pthreads, and Linux mmap are sufficient.
The runner compiles the complete `core/fork_arena.cc` body and production header
with platform includes substituted. It does not implement a second allocator.
Test-only scheduling hooks are inserted into the temporary translation unit;
none are compiled into the kernel.

From the repository root:

```sh
ulimit -c 0
python3 tests/fork-arena-host/run.py
python3 tests/fork-arena-host/run.py --sanitize address,undefined
python3 tests/fork-arena-host/run.py --sanitize thread
# Deliberate negative: must fail live-pointer uniqueness (case -6, runner 1).
python3 tests/fork-arena-host/run.py --remove-pop-lock descriptor-lock
```

The tests use the real production fixed addresses. TSan may reject those
addresses or fail before main because of its shadow-memory layout; such a run
is **unavailable**, not a pass. The mutex substitute checks that the slow path
has entered the identity-heap scope and is IRQ-enabled/preemptable. It does not
validate OSv mutex waiter allocation or scheduler implementation.

## Cases

- `publication`: stop the creator immediately after owner publication; a second
  thread allocates/writes before the creator resumes. Subsequent allocation must
  neither alias nor erase the live allocation.
- `collision`: pause the first mapper until a second allocator reaches mapping
  (old code) or growth-lock acquisition (fixed code). The second proceeds after
  the first returns and writes. Real Linux MAP_FIXED has the destructive
  replacement semantics relevant to OSv `evacuate()`. Check live data and uniqueness.
- `boundary-cas`: pause a small carve before CAS, grow a larger region, then
  resume. Its stale cursor must not allocate from the abandoned tail or alias
  the larger live allocation.
- `publish-free`: pause growth just after publishing end; another thread carves
  and frees. The free must see the published mapped high-water and recycle.
- `boundaries`: failed-map retry, carve rejection with IRQs disabled, growth
  fallback with IRQs/preemption disabled, mixed-size growth, exact final-window
  fit, exhaustion, quiescent teardown and slot/address-space-pointer reuse.
- `threads`: four same-AS threads allocate mixed sizes over many regions; check
  every live byte and pointer uniqueness, then sequential free/recycling.
- `vma-order`: compile the actual `procfs_maps()` body with a test VMA-lock
  facade and formatting allocator routed through the real arena. Force a VMA
  reader to allocate while a grower waits for VMA write access; completion and
  formatted output must remain correct. Platform locks are substituted: this
  is a lock-order witness, not guest scheduler proof.
- `null`: a null AS must not match the free-slot sentinel.

For the original regressions, extract the immutable base and run the same tests:

```sh
git show a12f20345268e4b0421a92e4f8d199abda3fd1d2:core/fork_arena.cc > /tmp/arena-before.cc
python3 tests/fork-arena-host/run.py --source /tmp/arena-before.cc publication collision publish-free null
```

These four cases must fail on the base; `boundary-cas` and `boundaries` also test
properties that already held before the fix. A crash in `collision` on the base
is expected: its losing mapper unmaps the published allocation before returning.
For R1, keep the fixed arena source but pass `--mmu-source /tmp/mmu-before.cc
vma-order` with MMU source extracted from `add9441d9`: it must time out, while
current source completes. Growth mutex acquisition **and unlock** assert that
identity-heap scope is active.

## ABA / COW regressions

`aba` fails on reviewed phase1 source (`1c17f7339`): slow pop reads A->B,
second thread keeps B live and returns A, stale CAS republishes live B.
The identity-cache implementation has no out-of-lock head/link observation;
the hook pauses before pop instead, and the same competing allocations must
leave B uniquely owned. This pre-pop control alone does not prove descriptor
locking. The default `descriptor-lock` pauses after the descriptor index read
inside the actual locked pop. A rival's failed host `try_lock` reports actual
contention; the controller resumes the owner only after contention or rival
completion, with no sleep-based success oracle. Both allocations must complete
with distinct live pointers, and contention must have occurred.
`--remove-pop-lock descriptor-lock` removes only pop's lock in the temporary
translation unit: the rival completes before the suspended reader, which then
reissues its live chunk and fails the uniqueness assertion. This is an intended
failing invocation, not a test that converts any nonzero result into success.
`recycle-stress` checks simultaneous live ownership and
payload under 80,000 concurrent alloc/free operations.

`readonly-free` holds the test VMA lock while freeing a read-only page; the
old in-band link write SIGSEGVs, while fixed free writes identity metadata only.
The header is intact and resident in this test; depopulated/protected/unmapped
or arbitrary foreign allocations do not have a general VMA-held free guarantee.
A second VMA claimant must progress. This is NOT an actual JVM/fileref callback
or an OSv COW-fault schedule. `atomic-touch` protects the arena page PROT_NONE
and checks both IRQ-off/preempt-off entry guards precede any header/link access.
`cache-bound` frees 1025 chunks: exactly 1024 recycle, one is dropped, byte
accounting counts accepted entries only, live pointers stay unique, and
quiescent slot reset restores reuse. The fixed cache costs ~4 MiB BSS; dropped
entries retain their mapping until AS teardown. This is a bounded correctness
policy, not an unlimited-churn memory guarantee.

## Guest integration

`tests/tst-fork-arena-concurrency.cc` is registered as
`tst-fork-arena-concurrency.so` in `modules/tests/Makefile`. It uses the real
malloc, scheduler and MMU, with no injected scheduling hooks. Run on an enabled
`conf_fork=1` test image with reclaim/recycling enabled, at least 1.5 GiB RAM and
preferably at least two CPUs. It forces overflow while retaining live allocations,
checks concurrent live-pointer/payload recycling, parent/child COW free and
IRQ-off/preempt-off direct arena rejection (global and overflow), concurrent
mixed-size allocation data, sequential recycling, and repeated child teardown.
Direct arena rejection is NOT a safe-public-malloc-fallback claim. It does **not** force the publication interleavings, and it does
not claim to validate concurrent destruction of an AS with live threads. The
allocator's release contract requires all AS users (including growth waiters) to
have quiesced before the caller destroys page tables and releases the slot.
