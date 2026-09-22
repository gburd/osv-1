# ALLOCATOR MICROBENCHMARK: is OSv's malloc/free ~2x Linux's on the parser's allocation shape?

STATUS: IN PROGRESS. Written from first tool call, updated continuously.

## BOX IDS (FIRST, as required)
| role | instance id | type | AZ | state |
|------|-------------|------|----|-------|
| (not yet launched) | | | | |

## TEARDOWN
not yet run.

---

## PRE-SPEND SOURCE FINDING THAT CORRECTS THE BRIEF (recorded before any box)

### (1) The brief names the WRONG allocator for PG's app-side allocations in THIS tree.
The brief's leading candidate is `core/mempool.cc`'s per-CPU small pools with cross-CPU frees routed
through spsc garbage sinks (mempool.cc:125-128). But the benchmarked AMIs are built `conf_fork=1`,
and `core/mempool.cc:2118-2140` `std_malloc()` reads:

```c
if (smp_allocator && fork_arena::ready() && !fork_arena::force_kernel_heap &&
    sched::cpu::current()->app_thread.load(std::memory_order_relaxed)) {
    ret = fork_arena::alloc(size, alignment);
    if (ret) { ... return ret; }
}
```

So **every allocation made by an APP thread goes to `fork_arena`, not to mempool's per-CPU pools.**
mempool is reached only by KERNEL allocations, or when the arena declines (size > 2 MiB, or exhausted).
`free()` decides purely by address (`fork_arena::contains`), so app frees go back to the arena too —
including cross-CPU frees, which therefore **never enter the spsc garbage sinks at all**.

Corroborated by the prepared-run profile (`.local/prepared/raw/syms-B.txt`), where both allocators
appear simultaneously, which is what "app in arena, kernel in mempool" predicts:

| symbol | cell A (simple) | cell B (prepared) |
|---|---|---|
| `fork_arena::alloc` | 0.18% | 0.33% |
| `memory::pool::alloc` | 0.34% | 0.47% |
| `memory::pool::free_different_cpu` | 0.27% | 0.32% |

So the mempool/spsc story can still explain KERNEL-side allocation cost, but it cannot be the
mechanism behind an **app-side** parse/plan multiplier. That part of the brief's narrowing is wrong
on this tree.

### (2) A better-shaped suspect: `fork_arena::slot_for()` is O(live address spaces) per alloc AND per free.
`core/fork_arena.cc:104`:

```c
// note: O(max_as_slots) linear scan per alloc/free; owners pack from
// index 0 so the common case is a short scan.
for (unsigned i = 0; i < max_as_slots; i++)          // max_as_slots == 256
    if (g_as_freelists[i].owner.load(acquire) == as) return &g_as_freelists[i];
```

Every `malloc` and every `free` by an app thread linear-scans a 256-entry table of
`std::atomic<void*>` to find the current address space's free-list head. With one process that is
1 iteration. **PostgreSQL forks a backend per connection**, so at VU128 a late backend's slot index
is ~100 and it pays a ~100-iteration scan (each an acquire load over ~4 KB of shared cache lines,
touched by every other process) **on every malloc and every free**.

That is a per-allocation cost that scales with **CONNECTION COUNT**, which is the one axis a
single-process microbenchmark cannot see. It is why this benchmark has a MODE P (forked children).

### (3) A CAVEAT I WILL HONOUR WHATEVER THE RESULT (stated in advance so it cannot be motivated later)
PG's `palloc` serves most requests out of already-allocated memory-context blocks and calls `malloc`
only when a context needs a fresh block. So PG's **malloc rate is much lower than its palloc rate**.
If this microbenchmark shows OSv ~2x on raw malloc/free, that names a real OSv allocator defect, but
it does **not** automatically carry the ~104 µs parse/plan cost — the arithmetic from malloc-rate to
µs/txn has to be shown, and this experiment does not measure PG's malloc rate. I will not claim it.

---

## THE BENCHMARK
Source: `.local/alloc/bench-alloc.c` (in this directory, committed). One source, three arms.

Two modes, one invocation (`-A` runs a fixed matrix so every arm executes byte-identical work —
required because the OSv arm has no shell and gets exactly one command line):

- **MODE T** — `nthr` pinned threads, live ring of `depth` pointers each, oldest freed on each alloc,
  a target fraction `xfrac` of frees handed to another (pinned, hence different-CPU) thread via a
  64-slot inbox and freed there. Tests the brief's mempool/spsc story. Matrix:
  (32 thr, 0%), (32, 25%), (32, 100%), (4, 0%), (4, 25%).
- **MODE P** — `nproc` **forked single-threaded children**, each running the same loop with no
  cross-thread frees. This is a PG backend's actual shape and the only configuration that exercises
  `fork_arena`'s per-address-space table. Matrix: 32 procs, 128 procs.

Size distribution (identical in all arms, deterministic LCG, no libc RNG):
`{24,32,32,40,48,48,64,64,80,96,112,128,160,200,256,512}` bytes, indexed by `rng & 15` —
weighted to the small end, max 512 B, i.e. the parse-node size classes.
Each allocation writes `p[0]` and `p[sz-1]` so the arm cannot optimise the allocation away and both
ends of the object are actually faulted/dirtied.

Reported per rep: allocations/sec, **ns per alloc+free pair** (wall x threads / pairs, so it is a
per-CPU-second cost, not a throughput restatement), the **ACHIEVED** cross-CPU free fraction
(measured, not assumed), absolute pair count, bytes, and distinct CPUs observed.

## LOG
- t0: read `.local/MULTIPLIER-MECHANISM-NARROWED.md`, `.local/PREPARED-DISCRIMINATOR-ANSWER.md`.
- t1: read `core/mempool.cc`, `core/fork_arena.cc`, `include/osv/fork_arena.hh`, `loader.cc`,
  `fs/vfs/main.cc`, `fs/rofs/rofs_vfsops.cc` -> findings (1) and (2) above.
- t2: wrote `bench-alloc.c`. Verified `scripts/gen-rofs-img.py` runs standalone locally (no OSv build
  needed) — produced a valid ROFS image from a hand-written manifest.
- t3: delivery plan settled, **NO OSv IMAGE BUILD**: ship the musl-linked PIE on a second EBS volume
  as a ROFS filesystem, and rewrite the stock AMI's sector-1 cmdline to
  `--rootfs=ramfs --mount-fs=rofs,/dev/vblk1,/mnt /mnt/bench.so -A`, reusing the already-proven
  sector-1 patch mechanism from `.local/prepared/remote-sect1.sh`.
