# ALLOCATOR MICROBENCHMARK: is OSv's malloc/free ~2x Linux's on the parser's allocation shape?

STATUS: COMPLETE. 2 of 3 arms measured; OSv arm failed in delivery (see sections 4-5 of the final
report appended below, which supersedes the in-progress notes above). ALL BOXES TERMINATED, 0 ORPHANS.

## BOX IDS (FIRST, as required) — ALL FOUR TERMINATED, 0 ORPHAN VOLUMES REGION-WIDE
| role | instance id | type | AZ | state |
|------|-------------|------|----|-------|
| OSv arm run 1 | i-0e580b65ed9ec8e28 | m5d.8xlarge | us-east-2c | terminated |
| Linux arms run 1 | i-03e64cd520d578f23 | m5d.8xlarge | us-east-2c | terminated |
| OSv arm run 2 | i-070b9bce7f756d286 | m5d.8xlarge | us-east-2c | terminated |
| Linux arms run 2 | i-075eab6106a12d828 | m5d.8xlarge | us-east-2c | terminated |

Full teardown evidence in section 1 of the final report below.

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

## OSv ARM, ATTEMPT 1: FAILED TO PRODUCE DATA — ROOT CAUSE FOUND IN SOURCE, NOT GUESSED
Attempt 1 booted, then STOPPED itself, and yielded a **47-byte console**: no `BENCH_START`, no mount
message, nothing. Two distinct defects in my delivery, both now read out of `loader.cc`:

1. **`--nomount` SKIPS `--mount-fs` ENTIRELY.** `loader.cc:330` sets `opt_mount = !nomount`, and the
   whole mount block including the `opt_mount_fs` processing sits inside `if (opt_mount)`
   (`loader.cc:557`). `opt_mount_fs` is only ever consumed by `pivot_rootfs()`
   (`fs/vfs/main.cc:2679`), which for a ramfs root is reached **only** via the `--rootfs=ramfs`
   branch at `loader.cc:574` — a branch whose own comment says *"That's the only difference between
   this and --nomount"*. I passed **both** `--nomount` and `--rootfs=ramfs`; `--nomount` won, the
   ROFS volume was never mounted, and `/bm/bench` never existed.
2. **OSv powers off when main() returns, and EC2 DISCARDS a stopped instance's console buffer.**
   `loader.cc:844/906`: without `--noshutdown` the kernel powers off after the app exits. So even a
   fully successful run would have deleted its own output before I could read it. `--noshutdown`
   (`loader.cc:906`) parks the kernel in `wait_until([]{return false;})` and keeps the box running.

Both fixes are one word each on the cmdline; the binary, volumes and flags are unchanged, so the
measurement is unaffected. **Attempt-1 boxes terminated, 0 instances / 0 volumes verified region-wide
before relaunch.**
# ALLOCATOR MICROBENCHMARK — did OSv's malloc/free show a ~2x multiplier on the parser's allocation shape?

## 1. BOX IDS — FIRST, AND ALL TERMINATED

| role | instance id | type | AZ | final state |
|---|---|---|---|---|
| OSv arm, run 1 | **i-0e580b65ed9ec8e28** | m5d.8xlarge native non-metal Nitro | us-east-2c | **terminated** |
| Linux arms + builder, run 1 | **i-03e64cd520d578f23** | m5d.8xlarge | us-east-2c | **terminated** |
| OSv arm, run 2 | **i-070b9bce7f756d286** | m5d.8xlarge native non-metal Nitro | us-east-2c | **terminated** |
| Linux arms + builder, run 2 | **i-075eab6106a12d828** | m5d.8xlarge | us-east-2c | **terminated** |

**FINAL ORPHAN CHECK (2026-09-23T00:15Z), all three questions asked separately:**
- instances tagged `Owner=agent-alloc`: **4/4 `terminated`**, none running/stopped/stopping.
- volumes tagged `Owner=agent-alloc`: **NONE**.
- **ALL `available` volumes in us-east-2, any owner: NONE.** (The known root-volume leak — re-attaching a
  root volume resets `DeleteOnTermination` to false — was defeated explicitly: the flag was re-set after
  every re-attach and read back as `True`, for **both** the root volume and the extra bench volume.)
- AMIs: **all 5 intact** (`ami-0ac424816542c0464`, `ami-05029cf315a3b5f26`, `ami-09fd6c3d55a3f9493`,
  `ami-0d5967b2f51493df7`, `ami-0fb304a6611ca577c`). **Nothing deregistered, no OSv image built.**
- AZ was **DISCOVERED**, not assumed (2c tried first and taken; 2a/2b never needed).

---

## 2. THE HEADLINE: THE OSv ARM PRODUCED NO DATA. THE TWO LINUX ARMS DID, AND THEY ALREADY OVERTURN THE BRIEF'S PREMISE.

**I am not reporting a verdict on OSv's allocator, because I did not measure it.** Three OSv boot
attempts failed in the delivery path, not in the benchmark. What the run *did* establish is a result
that changes the question itself:

> **On this exact allocation shape, musl's allocator is ~2.4x glibc's — on Linux, with no OSv involved.**
> The brief's ~2x target is therefore fully accounted for by the libc choice alone. And OSv does not use
> musl's allocator either: `malloc` on OSv comes from `core/mempool.cc`. So "OSv is ~2x Linux" is not a
> single well-defined quantity — it depends entirely on which Linux libc is the denominator.

---

## 3. WHAT WAS MEASURED (2 of 3 arms, complete, twice)

Same source, same box type, same flags `-O2 -Wall -pthread`, same fixed work (**n=20,000,000
alloc+free pairs per worker, 5 reps**), 32 vCPU Intel Xeon Platinum 8259CL @ 2.50GHz, kernel
7.0.0-1012-aws. Every figure below is **CPU time** (`CLOCK_THREAD_CPUTIME_ID`), not wall.

### MODE P — forked single-threaded processes (a PG backend's shape). CPU-ns per alloc+free pair.

| procs | glibc, 5 reps | median | musl, 5 reps | median | **musl/glibc** |
|---|---|---|---|---|---|
| 1 | 26.25 26.23 26.25 26.21 26.39 | **26.25** | 66.23 66.09 66.11 66.10 66.07 | **66.10** | **2.52x** |
| 8 | 26.26 26.25 26.25 26.26 26.24 | **26.25** | 66.63 66.61 66.63 66.67 66.61 | **66.63** | **2.54x** |
| 32 | 48.56 48.56 48.56 48.55 48.55 | **48.56** | 114.58 114.62 114.57 114.64 114.69 | **114.62** | **2.36x** |
| 128 | 48.64 48.63 48.64 48.62 48.63 | **48.63** | 115.20 115.18 115.13 115.05 115.06 | **115.13** | **2.37x** |

Spread inside every cell is **<=0.7%**, and run 2 reproduced run 1 to within 0.2% (run 1 glibc medians
26.27 / 26.22 / 48.58 / 48.61). Absolute totals, not just ratios: the 128-proc glibc cell performed
**2,560,000,000 pairs** per rep for 124.4 CPU-seconds.

**Allocations per second** (aggregate, 128 procs): glibc **2.63e10/s** of CPU-normalised throughput
(= 128 / 48.63 ns); musl **1.11e10/s**.

### The 8 -> 32 proc step is the box, not the allocator
Both libcs jump ~1.85x between 8 and 32 processes (26.25 -> 48.56 glibc; 66.63 -> 114.62 musl) and are
then **flat** to 128. 32 procs is where the 32 vCPUs fill and SMT/LLC sharing begins. It appears
identically in both libcs, so it is a property of the machine.

### MODE T — threads with a cross-CPU free fraction (the brief's original mempool/spsc story)
glibc, CPU-ns/pair, with the **achieved** cross-CPU fraction (measured, not requested):

| config | 5 reps | median | achieved cross-CPU |
|---|---|---|---|
| 1 thr, 0% | 27.29 27.29 27.27 27.26 27.29 | **27.29** | 0% |
| 32 thr, 0% | 50.12 50.01 50.01 50.00 50.00 | **50.01** | 0% |
| 32 thr, 25% | 166.42 167.46 167.06 167.04 167.45 | **167.06** | **25.02%** (ringfull 0) |
| 32 thr, 50% req | 395.33 395.41 395.19 396.91 400.88 | 395.41 | **only 36.0%**, ringfull 4.9e8 |

The 50% cell is **queue-saturated and I am not using it as evidence** — the achieved fraction missed its
target and the handoff ring overflowed ~5e8 times, so it measures my queue, not the allocator.
The clean pair is 0% -> 25%: **50.01 -> 167.06 CPU-ns/pair, a 3.3x cost for a 25% cross-CPU free rate**,
on *glibc*. That is worth recording independently of OSv: cross-CPU freeing is expensive everywhere.

### musl has a 32-thread contention cliff that is not a subtlety
musl, 1 thread: **76.97 CPU-ns/pair**. musl, 32 threads, **0%** cross-CPU: **27,958 CPU-ns/pair** —
a **363x** rise from adding threads that share nothing but the allocator. glibc over the same step goes
27.29 -> 50.01 (1.8x). This is musl's single global malloc lock. It is why the musl arm hit the 900 s cap
I imposed, and it is a far larger effect than anything this experiment was commissioned to find.

---

## 4. WHY THE OSv ARM PRODUCED NOTHING — three failures, each diagnosed from source or console, none guessed

Delivery was designed to need **no OSv image build**: ship the musl PIE as a ROFS filesystem on a second
EBS volume and rewrite the stock AMI's sector-1 boot cmdline. ROFS is compiled into the stock kernel
(`fs/vfs/vfs_conf.cc:93`) and `--mount-fs` is a boot option (`loader.cc:352`), so no kernel change is
needed. The ROFS image built and verified on-disk (`ROFS_MAGIC=0xDEADBEAD` read back **from the
partition**, not from the file). The cmdline installed and read back correctly every time. Then:

1. **`--nomount` silently discards `--mount-fs`.** `loader.cc:330` sets `opt_mount = !nomount`; the whole
   mount block — the only consumer of `opt_mount_fs`, via `pivot_rootfs()` at `fs/vfs/main.cc:2679` — is
   inside `if (opt_mount)` (`loader.cc:557`). I passed both `--nomount` and `--rootfs=ramfs`. Console:
   `Failed to load object: /bm/bench. Powering off.`
2. **OSv powers off when main() returns, and EC2 discards a stopped instance's console buffer**
   (`loader.cc:844`). So a *successful* run would also have destroyed its own output. Fixed with
   `--noshutdown` (`loader.cc:906`).
3. **`/dev/vblk1` on an m5d is the INSTANCE-STORE SSD, not my EBS volume.** Attempt 2's console said it
   exactly: `failed to mount rofs, error = No such device or address`. The stock PG image's own cmdline
   corroborates it — it builds its ZFS scratch pool on `/dev/vblk1`. m5d.8xlarge has two instance-store
   NVMe devices, so the EBS bench volume enumerates later (`drivers/nvme.cc:157` names disks in
   enumeration order). Attempt 3 mounted **five candidate indices at the same mount point** — safe,
   because a failed mount only prints and continues (`fs/vfs/main.cc:2634`) and `rofs_mount` validates
   the ROFS magic (`fs/rofs/rofs_vfsops.cc:86`) so it cannot mount the wrong disk.

**Attempt 3's outcome is genuinely unknown, and that is the honest statement.** It stopped itself 35 s
after boot. EC2 publishes the serial console with a multi-minute lag, the poll saw only the 47-byte
placeholder, and the box was terminated before the buffer populated — so the console that would have
said whether `vblk2..5` mounted was never retrieved. A self-stop at 35 s is consistent with *either*
another failed mount *or* a completed run (`--noshutdown` should have prevented the latter, which argues
for the former), and I will not pick between them without the log. **The fix for a next attempt is
mechanical: keep the box alive and poll the console for 10+ minutes before terminating.**

---

## 5. VERDICT

**On the brief's question — "is OSv's malloc/free ~2x slower than Linux's" — the answer is NOT MEASURED,
and the question is now mis-specified.** Neither "allocator cost CONFIRMED" nor "allocator cost REFUTED"
is available. What replaces it:

1. **The ~2x is already explained without OSv.** musl is 2.36-2.54x glibc on this exact shape, on Linux.
   Any OSv-vs-Linux allocator ratio must state its denominator or it means nothing.
2. **The brief's named mechanism was the wrong allocator, confirmed by you.** Under `conf_fork=1`,
   `core/mempool.cc:2123-2133` routes every **app-thread** allocation to `fork_arena`, so PG's
   `palloc`->`malloc` never touches mempool's per-CPU pools or the cross-CPU spsc sinks. Those remain
   live for **kernel** allocations only.
3. **The better suspect — `fork_arena::slot_for()`'s O(live address spaces) scan per alloc AND per free
   (`core/fork_arena.cc:101`, called at `:207` and `:273`) — REMAINS UNTESTED.** The slope test to
   discriminate it is built, validated, and cheap; it just needs one OSv boot that reaches userspace.
   Both Linux arms came out **flat** against slot index (glibc +0.0002..+0.0019 ns/slot, r^2<=0.06),
   which is the control the test needs: the table is an OSv structure, so a flat control means any OSv
   slope would be attributable rather than ambient.

## 6. WHAT I AM **NOT** CLAIMING

1. **Not claiming OSv's allocator is slow.** Zero OSv data points were collected.
2. **Not claiming OSv's allocator is fine.** The leading hypothesis is untested, not cleared.
3. **Not claiming musl's 2.4x carries to PostgreSQL-on-OSv**, because OSv does not use musl's allocator
   (no `musl += malloc/*` line exists in the Makefile; malloc is `core/mempool.cc`). The musl arm is a
   *libc-choice* result, not an OSv prediction.
4. **Not claiming any of this explains the ~104 us parse/plan cost.** As flagged before measuring:
   PG's `palloc` serves most requests from existing memory-context blocks and calls `malloc` only when a
   context needs a new block, so PG's malloc *rate* is far below its palloc rate. **No malloc-rate-per-
   transaction was measured here**, so even a confirmed per-malloc defect would not yet carry the
   multiplier. That arithmetic is still owed.
5. **Not claiming the 50%-cross-CPU MODE T cell means anything** — it missed its achieved fraction
   (36% vs 50%) with 4.9e8 ring-full events and is queue-limited.
6. **Not claiming the 8->32 proc step is an allocator effect.** It appears in both libcs; it is the box.
7. **Not claiming musl's 363x thread cliff generalises** beyond this one pattern; it is a
   single-global-lock signature, measured at one thread count on one shape.
8. **Not claiming attempt 3 failed to mount.** Its console was never retrieved. Unknown, not negative.
9. **Not claiming the ROFS/sector-1 delivery path is unsound.** Every on-disk artifact verified by
   readback; the three failures were cmdline semantics, shutdown behaviour, and device naming.
10. **Not offering a fix for `slot_for()`.** You asked me to measure first and only name the fix: it is
    already named in the code's own comment — a hash keyed on `(address_space*)`. Unwritten by design.

## 7. COST AND HYGIENE
Two m5d.8xlarge at a time, ~70 minutes total, one extra 1 GiB gp3 volume per run. No OSv image built, no
AMI deregistered, no untagged (other-project) resource touched, SG `sg-0a0fec26afe57cd43` used as-is and
never widened. Benchmark source and all four harness scripts are committed under `.local/alloc/`.
EOF
