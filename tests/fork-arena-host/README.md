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
- `boundaries`: failed-map retry, existing carve with IRQs disabled, growth
  fallback with IRQs/preemption disabled, mixed-size growth, exact final-window
  fit, exhaustion, quiescent teardown and slot/address-space-pointer reuse.
- `threads`: four same-AS threads allocate mixed sizes over many regions; check
  every live byte and pointer uniqueness, then sequential free/recycling.
- `null`: a null AS must not match the free-slot sentinel.

For the original regressions, extract the immutable base and run the same tests:

```sh
git show a12f20345268e4b0421a92e4f8d199abda3fd1d2:core/fork_arena.cc > /tmp/arena-before.cc
python3 tests/fork-arena-host/run.py --source /tmp/arena-before.cc publication collision publish-free null
```

These four cases must fail on the base; `boundary-cas` and `boundaries` also test
properties that already held before the fix. A crash in `collision` on the base
is expected: its losing mapper unmaps the published allocation before returning.

## Known independent failure — NOT fixed

```sh
python3 tests/fork-arena-host/run.py aba
```

This intentionally fails on both the base and the FB02/FB03 fix. A slow pop reads
A->B; a second thread pops A and B (keeping B live) and pushes A; the stale pop
then republishes B. The next allocation returns the already-live B. Concurrent
free-list operations still require a separate COW-safe fix. This case is not in
the green default cases, and must not be represented as an allocator-wide pass.

## Guest integration

`tests/tst-fork-arena-concurrency.cc` is registered as
`tst-fork-arena-concurrency.so` in `modules/tests/Makefile`. It uses the real
malloc, scheduler and MMU, with no injected scheduling hooks. Run on an enabled
`conf_fork=1` test image with reclaim/recycling enabled, at least 1.5 GiB RAM and
preferably at least two CPUs. It forces overflow while retaining live allocations,
checks concurrent mixed-size allocation data, sequential recycling, and repeated
child teardown. It does **not** force the publication interleavings, and it does
not claim to validate concurrent destruction of an AS with live threads. The
allocator's release contract requires all AS users (including growth waiters) to
have quiesced before the caller destroys page tables and releases the slot.
