# Third cause, revised again: it is an O(PTEs x ranges) scan, NOT an IPI broadcast

2026-09-07. Agent 5052cc0d revised the diagnosis before building anything. Both of
its findings verified independently by me. My broadcast hypothesis was wrong.

## Finding 1 (SAFETY): a local-only TLB flush is UNSOUND - two CPUs can share one CR3

I had asked whether two CPUs can execute in the same child address space. The answer
is a hard YES, so the local-flush optimization I proposed must not ship.

- `libc/signal.cc` (~line 718) explicitly assigns a NEWLY SPAWNED detached
  signal-handler thread into a LIVE fork child's address space:
  `t->set_address_space(target_as ? target_as : mmu::kernel_address_space())`
  where `target_as = as_for_pid(pid)`. That is precisely PostgreSQL's cross-backend
  latch wakeup (`latch_sigurg_handler` touching the target backend's self-pipe).
- `core/sched.cc` (~line 1382): every new thread INHERITS `_current_as` from its
  creator, so any thread a child spawns shares the child's AS.

Therefore a handler thread can be scheduled on another CPU with the SAME CR3 as the
backend, and a local-only flush would leave a stale writable/write-protected entry
live on that other CPU.

**This also means the EXISTING `exception_depth >= 2` local-flush path (core/mmu.cc
~2542) rests on an invariant that signal.cc can violate.** It is narrow - it needs a
concurrent same-page write from the handler thread - which is presumably why it has
not been observed. But that is a latent memory-corruption risk, not a performance
issue, and it is now on the record as its own finding. Candidate mitigations noted
but NOT to be built as part of the perf task: force a global flush when a
handler-thread-in-child-AS exists, or refuse to install a handler thread into a live
child AS while a COW fault is in flight.

## Finding 2 (PERF): the ~150 ms/fork is a linear scan, not IPI

The agent's decisive argument: one 32-way IPI round is tens of MICROseconds; the
measured cost is 150 MILLIseconds - three orders of magnitude off. So the broadcast
cannot be the mechanism.

What actually costs: `mmu::clone_address_space()` uses `sched::with_all_threads()` to
push EVERY live thread's stack into `share_ranges` (it even
`reserve(n + threads + 16 + ...)`), and then `clone_pt_level0` calls
`addr_is_privatize(va)` / `addr_is_shared(va)` **inside its
`for (i < pte_per_page)` loop** - and both are plain linear scans:

    static bool addr_is_shared(uintptr_t va) {
        for (auto &r : *cow_share_ranges) { if (va >= r.start && va < r.end) return true; }
        return false;
    }

So the PT-clone walk is **O(PTEs x ranges)**, and the range count scales with live
thread count. OSv pins ~2 threads per CPU (`idle_thread`, `page_pool_l1_<id>`), so
smp32 has ~64 more entries to scan per PTE than smp2.

**That reproduces the measured discriminator exactly** - cost rising with vCPU count
on a completely idle guest - with no cross-CPU broadcast involved. It also re-reads
the `clear_page_erms` 1.6% in the host perf profile as the intermediate-table
allocation in `clone_pt_level<1>/<2>`, i.e. the same walk, rather than fork page
zeroing per se. And it is consistent with cost being FLAT against resident set size
(0 to 6000 MB touched, still ~150 ms), which never fit a page-table-size story.

## Direction set

Stop scanning linearly per PTE. Options, smallest-and-most-obviously-correct
preferred: sort the ranges once and binary-search; or exploit the fact that
`clone_pt_level0` walks VAs monotonically within a table and keep an advancing
cursor into a sorted list (O(1) amortized per PTE); or build an interval structure
once per clone. Care needed: the ranges may be unsorted/overlapping today, and
nothing else must depend on insertion order.

Measurement: the fork microbenchmark (K concurrent connects, K=1..32, idle guest),
which runs in minutes rather than a 5-minute gate. Success = the ~150 ms/fork floor
drops AND the vCPU sensitivity flattens (the 71.8 / 88.2 / 142.7 ms spread across
smp2/8/32 should compress). A pre-fix confirmation was also suggested: instrument
comparisons-per-clone and check it tracks thread count and correlates with latency.

## My errors in this thread, for the record

1. I proposed a local-only flush without checking whether two CPUs can share an AS.
   The answer was in `signal.cc` all along.
2. I attributed the 150 ms to an IPI broadcast without doing the order-of-magnitude
   sanity check that would have refuted it immediately (tens of us vs 150 ms).

Third correction of a premise of mine today. The pattern is consistent: I am
generating plausible mechanisms and not always cost-checking them before handing them
to an agent as a target. Cheap guard for future briefs: state the expected magnitude
of the proposed mechanism and compare it to the measurement BEFORE dispatching.
