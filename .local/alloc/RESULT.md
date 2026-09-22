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

---

## BOXES (LIVE RUN, launched 2026-09-22T23:04Z)
| role | instance id | type | AZ | state |
|------|-------------|------|----|-------|
| OSv arm | **i-0e580b65ed9ec8e28** | m5d.8xlarge native non-metal Nitro | us-east-2c (DISCOVERED) | running |
| Linux arms (glibc + musl) + builder | **i-03e64cd520d578f23** | m5d.8xlarge | us-east-2c | running |

Both arms are the SAME instance type. CPU: Intel Xeon Platinum 8259CL @ 2.50GHz, 32 vCPU, kernel 7.0.0-1012-aws.
Flags, all three binaries, from one source: `-O2 -Wall -pthread` (OSv arm adds `-fPIC -pie`, which OSv requires).
Fixed work: **n=20,000,000 pairs per worker, 5 reps**.

## ARM 2 RESULT: LINUX + GLIBC (complete, the control)
MODE P, CPU-ns per alloc+free pair, all 5 reps:

| procs | rep1 | rep2 | rep3 | rep4 | rep5 | median | spread |
|---|---|---|---|---|---|---|---|
| 1 | 26.28 | 26.30 | 26.26 | 26.20 | 26.27 | **26.27** | 0.10 (0.4%) |
| 8 | 26.22 | 26.23 | 26.24 | 26.21 | 26.20 | **26.22** | 0.04 (0.2%) |
| 32 | 48.58 | 48.61 | 48.57 | 48.55 | 48.58 | **48.58** | 0.06 (0.1%) |
| 128 | 48.66 | 48.66 | 48.59 | 48.60 | 48.61 | **48.61** | 0.07 (0.1%) |

**THE CONTROL IS FLAT, WHICH IS THE PREDICTION.** Slope of CPU-ns/pair against slot index:
+0.0013 ns/slot at 32 procs, +0.0004 at 128 (r^2 0.002-0.06, i.e. no relationship).
Raw binned slopes agree: at 128 procs the 8 bins read 48.5 -> 48.7 across slot 0 -> 127.
1 -> 128 processes costs glibc **+2.34 ns/pair total (+8.9%)**, and that step happens between 8 and 32
procs (26.2 -> 48.6), i.e. it is the box filling its 32 cores, not a per-process allocator cost.

MODE T (glibc): 27.3 CPU-ns/pair at 1 thread; 50.0 at 32 threads, 0% cross-CPU; 168.2 at 25% cross-CPU
(achieved 25.02%); 397.4 at requested 50% (achieved only 35.8%, ringfull 5.0e8 -> that cell is
queue-saturated and I will not use it as evidence).

**wall_nspp vs cpu_nspp is the confound receipt:** at 128 procs on 32 vCPU, wall-derived cost reads
194.8 ns/pair while CPU-derived reads 48.6. A wall-clock benchmark here would have reported a
4x "slowdown" that is purely 128 processes sharing 32 cores. Every number above is CPU time.

## ARM 3 RESULT: LINUX + MUSL — *** THE THIRD ARM IS DECISIVE, AND IT WAS NEARLY OPTIONAL ***
Same box, same source, same `-O2 -Wall -pthread`, same fixed work. Only the libc differs.

MODE P, CPU-ns per alloc+free pair, all 5 reps:

| procs | rep1 | rep2 | rep3 | rep4 | rep5 | median | glibc median | **musl/glibc** |
|---|---|---|---|---|---|---|---|---|
| 1 | 66.28 | 66.11 | 66.22 | 66.11 | 66.08 | **66.11** | 26.27 | **2.52x** |
| 8 | 66.71 | 66.71 | 66.82 | 66.74 | 66.65 | **66.71** | 26.22 | **2.54x** |
| 32 | 114.73 | 114.87 | 114.79 | 114.94 | 114.86 | **114.86** | 48.58 | **2.36x** |
| 128 | 115.56 | 115.71 | 116.14 | 116.20 | 115.78 | **115.78** | 48.61 | **2.38x** |

Spread within each cell <=0.6%. **musl's allocator is ~2.4-2.5x glibc's on this allocation shape,
ON LINUX, with no OSv involved.** musl-on-Linux is also FLAT against slot index (slope +0.0002 to
+0.0128 ns/slot), as expected: the per-address-space table is an OSv structure, not a libc one.

### WHY THIS MATTERS BEFORE THE OSv ARM EVEN REPORTS
The brief's headline question is "is OSv's malloc ~2x Linux's". A ~2.4x musl-vs-glibc gap on Linux
means **the brief's ~2x target is already fully accounted for by the libc choice alone**, before any
OSv code runs. So the OSv arm cannot be interpreted against glibc: the only interpretable comparison
is **OSv+musl vs Linux+musl**, which holds libc constant and isolates OSv's kernel/allocator routing.
Had I skipped this arm — it was the brief's optional "if you can get it cheaply" item — I would have
reported OSv-vs-glibc and mis-attributed a musl cost to OSv.

### *** A CORRECTION TO MY OWN ARM LABELS, FROM THE MAKEFILE (this changes the interpretation) ***
I called the arms "OSv+musl" and "Linux+musl" as if they shared an allocator. **THEY DO NOT.**
`grep '^musl += malloc' Makefile` returns **NOTHING**: of 586 `musl +=` object lines, not one comes
from musl's `src/malloc/` directory. OSv's `malloc`/`free`/`calloc`/`realloc` are exported from
**`core/mempool.cc`** (`OSV_LIBC_API`, and they appear in `exported_symbols/osv_libc.so.6.symbols`).
So on OSv, musl supplies headers, ctype, string, stdio etc. — **but the ALLOCATOR is OSv's own.**

Consequences, both of which cut against a clean reading:
1. **The brief's third data point cannot do the job the brief wanted.** "musl-on-Linux close to OSv =>
   it is MUSL's allocator" is **not available as an inference**, because OSv does not use musl's
   allocator at all. If the two land close it is a coincidence of two different allocators, not shared code.
2. **There is no arm that holds the allocator constant.** glibc, musl-on-Linux, and OSv are THREE
   DIFFERENT ALLOCATORS. The honest comparison is therefore three-way and descriptive, and the
   OSv-vs-Linux "ratio" depends entirely on which Linux libc you pick as the denominator — 26.3 ns
   (glibc) or 66.1 ns (musl). I will report both and privilege neither.
