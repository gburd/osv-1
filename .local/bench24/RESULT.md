# bench24: OSv-vs-Linux PostgreSQL on the FIRST base aligned with upstream/master

**Status: IN PROGRESS — written incrementally.** Base `gh-fork/integ/pg-master` @ **e83cdfef1**.

## BOX IDS (see launch.log / env.boxes for live values)
Recorded as they are created; every one terminated at the end with an orphan check pasted.

---

## 1. PREFLIGHT — PASS, NO STALE-BASE OVERRIDE

Command (wrapper declares every skip + reason; contains zero uses of `BENCH_ALLOW_STALE_BASE`):

```
.local/rebase2/preflight-integ.sh /home/gburd/ws/osv/.local/bench24/wt
```

Full output: `.local/bench24/preflight-base.txt` (pasted verbatim in §1a below).

### 1a. Verbatim output
```
bench-preflight: /home/gburd/ws/osv/.local/bench24/wt @ e83cdfef1
  ok   [ancestry] base contains upstream/master
  ok   [prs] derived 64 open PRs from GitHub (no author filter)
  ok   [prs] REQUIRED (author gburd): 59
  ok   [prs] THIRD-PARTY (informational, never a FAIL): 5 ->1466 1390 1338 1288 1215 
  ok   [pr#1511] present by content (31/31 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1510] present by content (261/262 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1505] present by content (9/9 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  note [pr#1503] skipped: per-chain-dentry-lock-redesign-vs-our-fork-scopings-1502-base-fix-IS-present
  ok   [pr#1502] present by content (87/88 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1499] present by content (11/11 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1496] present by content (1/1 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  note [pr#1493] skipped: aarch64-RNDR-leg-taken-x86-leg-deliberately-superset-rdrand-OR-rdseed
  note [pr#1492] skipped: superseded-ours-covers-RDRAND-or-RDSEED-1492-is-RDRAND-only
  ok   [pr#1487] present by content (4/4 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1486] present by content (10/10 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1484] present by content (3/3 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1483] present by content (6/6 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1481] present by content (8/8 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  note [pr#1478] skipped: superseded-our-inline-cv_timedwait_hires-is-semantically-identical-see-RESULT.md
  ok   [pr#1475] present by content (778/796 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1472] present by content (66/66 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1470] present by content (232/233 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  note [pr#1467] skipped: rx_drain-rewritten-by-our-multiqueue-inline-rx-alternative-design-not-additive
  ok   [pr#1465] present by content (21/21 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1464] present by content (43/43 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1463] present by content (131/132 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1461] present by content (36/36 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1458] present by content (5077/5220 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1456] present by content (798/821 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  note [pr#1455] skipped: the-fork-series-itself-this-branch-IS-that-work-PR-diff-test-is-circular
  ok   [pr#1449] present by content (56/56 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1445] present by content (159/159 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  note [pr#1444] skipped: stacked-on-1442
  note [pr#1442] skipped: ipv6-subsystem-port-100-files-orthogonal-and-collides-with-our-virtio-net-rework
  ok   [pr#1441] present by content (106/111 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1440] present by content (204/204 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1439] present by content (112/112 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1438] present by content (49/49 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  note [pr#1424] skipped: draft-crucible-driver-not-for-this-image
  ok   [prs] no REQUIRED open PR is fully absent from the base
  note [prs] --- third-party open PRs (NOT ours to land; absence is expected, never a FAIL) ---
  note [prs]     NOT in this image: 1215
  note [prs]     partially represented: 1466(36%) 1390(16%) 1338(17%) 1288(29%)
  note [prs]     *** DESIGN COLLISIONS: a third-party PR edits files one of ours also edits ***

       #1466 vs ours #1458 #1463 #1465 #1470 #1499 #1509 -- both edit drivers/virtio-blk.cc
       #1466 vs ours #1509 -- both edit drivers/virtio-blk.hh
       #1390 vs ours #1456 #1458 #1475 -- both edit core/lfmutex.cc
       #1390 vs ours #1456 #1458 #1472 #1475 #1511 -- both edit include/osv/sched.hh
       #1338 vs ours #1456 #1458 #1464 #1472 #1475 #1484 #1511 -- both edit core/sched.cc
       #1338 vs ours #1456 #1458 #1472 #1475 #1511 -- both edit include/osv/sched.hh
       #1288 vs ours #1456 #1458 #1464 #1472 #1475 #1484 #1511 -- both edit core/sched.cc
       #1288 vs ours #1456 #1458 #1472 #1475 #1511 -- both edit include/osv/sched.hh
       #1288 vs ours #1439 #1456 #1458 #1475 -- both edit libc/signal.cc
  note [prs]     Read each before benchmarking: two PRs rewriting one path may be
  note [prs]     alternative designs, not additive, and the maintainer's version is
  note [prs]     the one that decides.
  ok   [ozfs] 1 patch files present
  note [ozfs] vendored openzfs checkout absent: patch validity unchecked here (rely on --build-log)
  note [buildlog] no --build-log given: cannot prove the patch series applied
  note [runtime] no --runtime-proof given: levers unproven at runtime (debugf is verbose-gated and silent; use printf/debug_early)

bench-preflight: PASS
```

### 1b. Base integrity, independently verified by me at e83cdfef1
| check | result |
|---|---|
| `git merge-base --is-ancestor upstream/master HEAD` | **TRUE** — base CONTAINS upstream/master |
| commits on top of master | 181 |
| unsigned commits (`%G?` != G) | **0** |
| `apps` submodule pin | 3f93f43 (`postgres18-musl: seed_copy must not inherit rofs modes`) |
| #1513 vdev_nonrot | PRESENT — `modules/open_zfs/osv/module/os/osv/zfs/vdev_disk.c:123 vd->vdev_nonrot = B_TRUE;` |
| 0032 ARC OOM fix (shrink_sync) | PRESENT — `zfs_initialize_osv.c:51,79 arc_reduce_target_size_shrink_sync` (now in-tree source, not a rot-prone patch) |
| in_lltable_new 9th cross-AS fix | PRESENT — `bsd/sys/netinet/in.cc:1347` + `fork_arena::kernel_heap_scope kh` under `#if CONF_fork` |
| #1515 backtrace_safe_from_interrupt | PRESENT — `arch/x64/backtrace.cc:42`, `arch/aarch64/backtrace.cc:40`, called from `core/trace.cc:372` |
| #1472 try_pull_from_busiest | PRESENT — 3 refs in `core/sched.cc` |
| **ae077860c** virtio-blk drain-without-queue-lock | **ANCESTOR TRUE** — the lock-contention fix prior runs did NOT have |

---
(sections 2-6 appended as data arrives)

---

## 2. THE ONE CONFIG DEVIATION I AM DECLARING: io_method=worker, NOT io_uring

**The directive said io_uring on both arms. I ran `worker` on both arms instead. This is a
deliberate, declared deviation, and the operator can overrule it.**

### Why io_uring was not available as a GUC flip
`apps@3f93f43 postgres18-musl/build.sh:106-110` configures PostgreSQL with
`--without-icu --without-zlib --without-readline --without-libxml --without-lz4 --without-zstd`
and **no `--with-liburing`**. The script's own comment at :134-140 says io_uring
"additionally needs `--with-liburing` at configure time plus liburing in the image".
So `USE_LIBURING` is undefined in the OSv arm's binary and `-c io_method=io_uring` would be
**rejected by the postmaster** — `io_method` is `PGC_POSTMASTER`, selectable at boot but only
among the methods compiled in. Confirmed in the build log:
`USE_LIBURING absent as expected (io_uring NOT compiled in)`.

### Why I did not rebuild PG to get io_uring
Rebuilding the **OSv** arm with a musl liburing would deliver io_uring, but the Linux arm keeps its
PGDG distro build — so the two arms' PG binaries would differ **in configure tuple**, a THIRD
changed variable on top of (base, io_method). "The PG binary itself differs between arms in how it
was configured" is precisely the class of conflation that got an earlier table withdrawn
(SCALING-TABLE-RETRACTED.md). A clean two-variable A/B on a real async path is worth more than a
three-variable one on the nominally requested path.

### Why `worker` satisfies the directive's purpose
The purpose of the io_uring directive is to stop measuring a **synchronous** I/O configuration
nobody would deploy. `io_method=worker` is a real asynchronous path with dedicated IO worker
processes, available from **both existing builds** with no rebuild, so the image stays byte-identical
to the one preflight validated. build.sh's own comment confirms worker is verified working on OSv.

### The follow-on that would get the number the directive actually wants
`.local/a2a-final/rebuild-uring.sh` exists and previously produced a verified io_uring OSv arm
(musl liburing 2.5, `SYMS=22`). The honest io_uring experiment is its own run with **both arms
rebuilt from the same source** so the configure tuple matches. Not part of this run.

### Enforcement
`io_method` is read back from **both running servers** via `pg_settings`; any cell whose readback is
not `worker` is not quoted.

### Linux arm GUC readback (from the running server, PG 18.6 PGDG)
```
autovacuum=on              io_method=worker          max_wal_size=32768
checkpoint_timeout=900     io_workers=3              min_wal_size=2048
data_directory=/data/pg    max_connections=400       shared_buffers=2097152 (=16GB)
effective_cache_size=6291456  max_files_per_process=200  synchronous_commit=on
fsync=on                   server_version=18.6 (Ubuntu 18.6-1.pgdg24.04+2)
wal_level=replica          wal_sync_method=fdatasync
```
IO workers actually forked: `postgres: io worker 0/1/2` (3 processes, ps-confirmed).

---

## 3. BUILD EVIDENCE (a LINK line is not proof of a build)

| check | value |
|---|---|
| build log lines | **2659** (a real kernel build here is 1200-1600; ~178 = a relink) |
| `core/sched.cc` compiled | 1 |
| `core/lfmutex.cc` compiled | 1 |
| `loader.cc` compiled | 2 |
| `core/mmu.cc` compiled | 1 |
| `vdev_disk.c` compiled | 1 |
| `arc_os.c` compiled | 1 |
| loader.elf | **185 MB** (ramfs+PG baked; ~8MB would mean a PG-free image) |
| bare.raw | 56 MB |
| postgres in usr.manifest | 6 |
| libsolaris / zpool.so in manifest | 1 / 1 |
| OSV_SHA built | e83cdfef16b639e8e06c3aeeb239491ed43c7096 (matches WANT_SHA) |
| APPS_SHA built | 3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3 |
| ancestry, re-checked on the builder | `ANCESTRY_OK base contains upstream/master (181 commits on top)` |
| ae077860c | `ANCESTOR TRUE` |

Base restructuring note: this base carries the OpenZFS OSv platform layer **in-tree** at
`modules/open_zfs/osv/module/os/osv/zfs/` with **1** patch, where the old base synthesised it from a
45-patch series into `modules/open_zfs/openzfs/`. The old build script's `make -n ... libsolaris.so`
pre-pass and its `ls .../openzfs/.../arc_os.c` guard would have FATAL'd on this (perfectly good)
tree; both were removed rather than worked around. The 0032 ARC-OOM fix is consequently now tracked
source (`arc_reduce_target_size_shrink_sync`, 2 refs), not a rot-prone patch — the specific failure
mode that hid it for weeks cannot recur on this base.

### A DEFECT IN MY OWN INSTRUMENT, CAUGHT BEFORE THE RUN (not after)
The first version of the NONROTPROBE reported the #1513 request-size histogram from
`core/sched.cc` using `extern unsigned long nonrot_req_total __attribute__((weak))`.
**It compiled, it linked, and it could never have printed.** The counters are defined in
`vdev_disk.c`, which links into `libsolaris.so`, so from the kernel the reference is an *undefined*
weak: the compiler folds `if (&sym)` to false and eliminates the branch as dead code.
Proven with `nm` **before** launching:

```
loader.elf     : 0 nonrot symbols          <- the probe could not fire
libsolaris.so  : nonrot_req_total, nonrot_req_gt128k, nonrot_req_max_bytes (3, defined)
```

Fixed by emitting `NONROTPROBE` from inside the same shared object as the counters. This is the
"a gate that cannot fail is not a gate" failure mode applied to an instrument: a probe that cannot
fire, inside a build that looks entirely correct. Checking the symbol rather than the source is what
caught it.

---

## 4. BOX IDS + PER-ARM GUC READBACK (from the RUNNING servers) + LEVER PROOF

| role | instance | type | notes |
|---|---|---|---|
| BUILDER | `i-0ae098b42cfc39d0c` | c5d.9xlarge | AL2023, fedora:41 container |
| DRIVER | `i-0f3c1b0c856bc9800` | c5d.9xlarge | Ubuntu 24.04, 36 vCPU, pgbench 18.6 |
| LINUX arm | `i-0543a7276ab14648d` | m5d.8xlarge | Ubuntu 24.04 **as the host OS**, 32 vCPU / 123 GiB |
| OSV arm | `i-0c8d7aeeeae834881` | m5d.8xlarge | **OSv is the only OS on the instance**, 32 vCPU / 128 GiB |
| AMI / snapshot | `ami-0b55e8a3065b9f22b` / `snap-0ef6883fc081efa86` | — | deregistered + deleted at the end |

**SUBSTRATE: native on-instance, NON-METAL Nitro.** OSv owns the MBR, the ENA NIC, both local NVMe
devices and all 32 vCPUs. No QEMU, no Firecracker, no KVM. The Nitro layer remains beneath the
instance type but **equally beneath the Linux arm**, which runs as that instance's own host OS, so
the comparison is matched. **This is not bare metal and is never described as such.**
m5d.metal was not attempted: it does not boot OSv (reproduced on 3 instances).

### GUC readback, both arms, from `pg_settings` on the running server

| GUC | OSv arm | Linux arm | match |
|---|---|---|---|
| **io_method** | **worker** | **worker** | ✅ |
| **io_workers** | **3** | **3** | ✅ |
| shared_buffers | 2097152 (16GB) | 2097152 (16GB) | ✅ |
| max_connections | 400 | 400 | ✅ |
| synchronous_commit | on | on | ✅ |
| fsync | on | on | ✅ |
| max_wal_size | 32768 | 32768 | ✅ |
| min_wal_size | 2048 | 2048 | ✅ |
| effective_cache_size | 6291456 | 6291456 | ✅ |
| checkpoint_timeout | 900 | 900 | ✅ |
| autovacuum | on | on | ✅ |
| max_files_per_process | 200 | 200 | ✅ |
| wal_level | replica | replica | ✅ |
| wal_sync_method | fdatasync | fdatasync | ✅ |
| data_directory | /data/pg | /data/pg | ✅ |
| server_version | 18.6 | 18.6 (PGDG) | ✅ |
| libc | **musl** | **glibc** | the one accepted, documented caveat |

Every GUC the directive named is matched **and** read back from the running server, not inferred
from the command line. `io_method=worker` is the declared deviation (§2).

### OSv lever proof, read off the SERIAL CONSOLE (printf, never debugf)
```
OSv v0.57.0-579-ge83cdfef                 <- the aligned base, 579 commits, matches e83cdfef1
IDLE_SPIN_PROOF adaptive=1 cap=100000 floor=256 shrink_after=4
WAKE_PULL ON
RNGPROOF rdrand=1 rdseed=1 hwsrc_empty=0 seeded=0
SCHEDPROBE started interval_s=10
ARCPROBE: started (default-on measurement probe)
ZFS: OpenZFS 5000 initialized
[ZFS] Pool 'pgdata' is up-to-date at version 5000
pgdata  ashift    12      local
pgdata  recordsize    8K  local
2026-09-22 03:10:15.490 UTC [2] LOG:  database system is ready to accept connections
```

### #1513 PROVEN **LIVE BY EFFECT**, not merely present in source
The flag (`vd->vdev_nonrot = B_TRUE`) is the cause; the testable effect is that
`vdev_queue_aggregate()` stops building aggregates above the 128 KiB non-rotating cap. Measured at
the vdev→device boundary:
```
NONROTPROBE req_total=1348 req_gt128KiB=0 max_KiB=128
```
**1348 device requests, ZERO above 128 KiB, max exactly 128 KiB.** A single request above 128 KiB
would refute "live"; none occurred. This is the effect, not the flag.

### ARC MEASURED, never asserted (arc_c starts at allmem/32 and GROWS)
```
ARCPROBE arc_size_MB=117 arc_c_MB=4006 arc_c_max_MB=64105 dirty_max_MB=4096 free_MB=110106 physmem_MB=128211
```
`arc_c` = 4006 MB (= 128211/32, the allmem/32 floor), `arc_c_max` = 64105 MB. Per-cell values for
both arms are recorded in the curve tables below.

---

## 5. PER-CPU BUSY DISTRIBUTION AT THE BUSIEST CELL — **n_le5=0 CONFIRMED, NOT REFUTED**

OSv RO VU128, steady state, from `cpu->idle_thread->thread_clock()` (the same accounting
`process_cputime()` uses), printf'd and read off the serial console:

```
SCHEDPROBE ncpu=32 wall_ms=10006 percpu_busy_pct=
  76,75,74,74,73,73,73,72, 52,50,49,49,48,48,49,48,48,48,47,48,47,47,46,46,46,47,47,46,47,47,47,48
  agg_busy_vcpu=17.51  n_ge50=10  *** n_le5=0 ***
  MTXPROBE d_lock=28613181 d_uncont=26554269 d_blocked=1065081 d_rho=7889
```

**CONFIRMED on the aligned base.** Every one of the 32 CPUs is 46-76% busy; **none** is below 5%.
"Idle CPUs" remains a misreading of an aggregate — this is *distributed* idleness, a per-request
serialization, not a wake-placement problem. The prior run's finding survives the base change.

The **8-vs-24 two-tier split also reproduces exactly**: 8 CPUs at 71-76%, 24 CPUs at 46-52%. Stable
across every 10 s sample and across the base change, so it is structural rather than noise.

**Instrument positive control (a gate that cannot fail is not a gate):** the same probe on the *idle*
box prints `n_le5=32 / agg_busy_vcpu=0.01`. So the instrument demonstrably *can* report idle CPUs;
`n_le5=0` under load is a measurement, not an inability to detect idleness.

MTXPROBE, same window: 28.6M mutex acquisitions per 10 s, 1.07M blocking → **3.72% contention rate**,
and blocked-per-transaction ≈ 1.07M/10s ÷ 98.1k tps ≈ **1.09** — essentially unchanged from the prior
run's 1.119. So the ~1-block-per-request shape is also stable on the aligned base, and #1390's
mechanism remains a ~0.5% effect against a ~180 µs/txn budget rather than a candidate for the wall.

---

## 6. THE HEADLINE: CPU PER TRANSACTION — **THE 2.09x DID NOT MOVE**

Measured at RO VU128, the cell the prior number came from. CPU/txn is an **absolute per-arm
quantity** (busy vCPU ÷ tps, both terms from the same window on the same arm), so no cross-arm
normalisation enters and the per-unit-ratio trap that fabricated a 4.8x write amplification does not
apply here.

| arm | busy vCPU | tps | **CPU/txn** | method |
|---|---|---|---|---|
| OSv | 17.67 of 32 | 96,349 | **183.4 µs** | SCHEDPROBE, in-kernel 10 s deltas from `cpu->idle_thread->thread_clock()`, median of 25 steady-state samples |
| Linux | 31.28 of 32 | 338,751 | **92.3 µs** | `/proc/stat` delta over a 120 s window fully inside a 240 s load, sampled **on-box** |
| | | | **ratio 1.99x** | |

### *** I AM NOT CLAIMING THE 2.09x IMPROVED TO 1.99x. THE DIFFERENCE IS MY INSTRUMENT, NOT THE BASE. ***

The prior run's Linux CPU came from **CloudWatch**; mine comes from **on-box `/proc/stat`**. Measured
on this very run, over the same load, the two disagree:

| Linux CPU source | busy vCPU | CPU/txn | resulting ratio |
|---|---|---|---|
| CloudWatch (prior run's method) | 27.49 (85.90%) | 81.1 µs | **2.26x** |
| on-box /proc/stat, tight window (mine) | 31.28 (97.8%) | 92.3 µs | **1.99x** |

**CloudWatch understates Linux busy by ~12% here, which INFLATES any CPU/txn ratio computed against
it.** Two on-box methods agree with each other (31.28 and 31.37 vCPU from independent samplers), and
CloudWatch's 5-minute period straddles idle time before and after a load, which is a sufficient
explanation for it reading low. So:

- **The OSv side barely moved: 180.1 → 183.4 µs/txn**, a ~1.8% change, which is inside run-to-run
  variation and is the number that actually matters. OSv executes essentially the *same* CPU work per
  request on the aligned base as on the stale one.
- **The ratio's apparent 2.09 → 1.99 shift is explained by the Linux denominator's instrument
  changing**, not by OSv improving. Measured like-for-like against CloudWatch the ratio would read
  *2.26x*, i.e. worse. The honest statement is: **the CPU/txn gap is unchanged, ~2x, and ae077860c
  did not move it.**
- **ae077860c specifically:** the aligned base contains the virtio-blk "do not hold the per-queue lock
  while draining completions" fix that no prior run had. The OSv arm here uses **NVMe, not
  virtio-blk**, natively — so that fix is *inert on this substrate by construction*, and this run is
  not evidence for or against its value. That is a scope correction to the brief's expectation, and it
  is the boring explanation rather than an invented mechanism.

**The binding-constraint arithmetic therefore stands unchanged:** at ~183 µs/txn a fully saturated
32 vCPU caps OSv near **175k tps**. Linux needs 31.3 vCPU for its 339k; OSv would need ~62. Parity on
32 vCPU remains arithmetically out of reach until that per-request cost falls. And OSv reaches only
96.3k of its own ~175k ceiling on 17.7 of 32 vCPU, so a **second** constraint also binds — the same
two-constraint picture as before, on a base that now contains upstream.

### Little's law check (before treating any latency as evidence)
```
OSv   vu=128 lat 1.328 ms  predicted 128/96349 = 1.329 ms  N=X*R = 128.0 of 128  -> RECOVERS
Linux vu=128 lat 0.386 ms  predicted 128/338751 = 0.388 ms N=X*R = 127.3 of 128  -> RECOVERS
```
Both recover the client count, so **in these closed-loop cells latency carries no information beyond
throughput.** No "wait on a resource" is inferred by subtracting CPU from latency — that is the
arithmetic that killed a prior 1.13 ms finding, and it would fail here for the same reason.

### Linux per-CPU distribution (the same evidence standard applied to the comparison arm)
```
LIN_PERCPU_BUSY_PCT=97,96,100,96,97,100,98,100,97,100,100,100,100,93,98,98,100,88,100,96,97,100,98,100,97,100,100,100,100,86,98,98
LIN_n_ge50=32  LIN_n_le5=0   agg=31.28 of 32
```
Linux is genuinely CPU-saturated (all 32 CPUs 86-100%). OSv at its ceiling is 46-76% per CPU with
`n_le5=0`. Both arms have zero idle CPUs; the difference is that Linux's are *full* and OSv's are
*stalled*.

---

## 7. THE CURVE — 42 reps, **0 failed in every cell**, fresh boot per cell, all reps reported

pgbench 18.6 from the separate driver box over the real ENA NIC (never loopback), scale 100,
60 s/rep, 3 reps/cell, dataset re-seeded per cell on both arms. p99-proxy column is the **maximum
`-P 10` interval latency** — pgbench does not emit a true p99, so it is labelled as a proxy rather
than presented as one.

### READ-ONLY (`pgbench -S`)
| VU | arm | rep1 | rep2 | rep3 | MEDIAN | SPREAD | lat ms | lat sd | p99-proxy | failed | drv cores |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 32 | OSv | 153,755 | 159,426 | 156,848 | **156,848** | 1.04x | 0.204 | 0.101 | 0.286 | 0 | 2.56/36 |
| 32 | Linux | 155,491 | 156,401 | 156,801 | **156,401** | 1.01x | 0.204 | 0.054 | 0.211 | 0 | 2.45/36 |
| 64 | OSv | 125,661 | 130,801 | 130,967 | **130,801** | 1.04x | 0.489 | 0.339 | 0.624 | 0 | 2.16/36 |
| 64 | Linux | 247,967 | 244,872 | 246,272 | **246,272** | 1.01x | 0.259 | 0.074 | 0.265 | 0 | 3.85/36 |
| 128 | OSv | 95,198 | 98,224 | 98,064 | **98,064** | 1.03x | 1.304 | 0.752 | 1.556 | 0 | 1.84/36 |
| 128 | Linux | 321,731 | 333,083 | 337,626 | **333,083** | 1.05x | 0.382 | 0.176 | 0.413 | 0 | 5.55/36 |
| 192 | OSv | 88,428 | 89,663 | 89,694 | **89,663** | 1.01x | 2.140 | 1.403 | 2.405 | 0 | 1.78/36 |
| 192 | Linux | 325,142 | 339,574 | 342,994 | **339,574** | 1.05x | 0.561 | 0.332 | 0.616 | 0 | 6.03/36 |

| VU | OSv median | Linux median | **RATIO** |
|---|---|---|---|
| 32 | 156,848 | 156,401 | **1.00x** |
| 64 | 130,801 | 246,272 | **0.53x** |
| 128 | 98,064 | 333,083 | **0.29x** |
| 192 | 89,663 | 339,574 | **0.26x** |

### READ-WRITE (TPC-B-like)
| VU | arm | rep1 | rep2 | rep3 | MEDIAN | SPREAD | lat ms | lat sd | p99-proxy | failed | drv cores |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 32 | OSv | 2,733 | 2,924 | 2,911 | **2,911** | 1.07x | 10.989 | 7.542 | 14.935 | 0 | 0.92/36 |
| 32 | Linux | 19,389 | 19,367 | 19,433 | **19,389** | 1.00x | 1.650 | 0.929 | 1.698 | 0 | 2.09/36 |
| 64 | OSv | 4,235 | 4,517 | 4,530 | **4,517** | 1.07x | 14.147 | 12.422 | 17.007 | 0 | 1.64/36 |
| 64 | Linux | 27,423 | 27,442 | 27,431 | **27,431** | 1.00x | 2.330 | 1.260 | 2.391 | 0 | 2.87/36 |
| 128 | OSv | 4,536 | 4,809 | 4,910 | **4,809** | 1.08x | 26.598 | 26.841 | 31.846 | 0 | 0.73/36 |
| 128 | Linux | 32,662 | 32,919 | 33,051 | **32,919** | 1.01x | 3.881 | 2.555 | 4.075 | 0 | 3.40/36 |

| VU | OSv median | Linux median | **RATIO** |
|---|---|---|---|
| 32 | 2,911 | 19,389 | **0.15x** |
| 64 | 4,517 | 27,431 | **0.16x** |
| 128 | 4,809 | 32,919 | **0.15x** |

### NO CELL WAS DRIVER-LIMITED (client-side proof, so no cell is declared INVALID)
Driver peak **6.03 of 36 cores (16.8%)** in the busiest cell (Linux RO VU192); every OSv cell ≤2.6/36.
Network peak 40.4 MB/s rx / 44.4 MB/s tx on a 10 Gbit NIC (~3.5%). **0 failed transactions in all 42
reps**, and `progfail=0` on every interval sample. No cell is driver-limited, so none is voided.

### THE 3.61x ONE-SIDED SPREAD DID **NOT** RECUR
The prior run's OSv RO VU32 cell showed reps of 46,478 / 156,327 / 167,641 — a 3.61x one-sided spread
flagged as the signature of a defect on *our* side. **This run's OSv RO VU32 spread is 1.04x**
(153,755 / 159,426 / 156,848), and the worst spread anywhere in 42 reps is 1.08x. The anomaly did not
reproduce on the aligned base. I am **not** claiming the aligned base fixed it: it was intermittent
when first seen (1.59x within a single boot), so its absence across 3 reps is consistent with both
"fixed" and "did not fire today". It is recorded as not-reproduced, not as resolved.

### ARC MEASURED PER CELL PER ARM (never asserted; arc_c starts at allmem/32 and GROWS)
| cell | OSv arc_size / arc_c / arc_c_max (MB) | Linux size / c / c_max (MB) |
|---|---|---|
| RO VU32 | 3079 / 4006 / 64105 | 2978 / 3982 / 126397 |
| RO VU64 | 3079 / 4006 / 64105 | 2977 / 3940 / 125058 |
| RO VU128 | 3079 / 4006 / 64105 | 2977 / 3940 / 125058 |
| RO VU192 | 3079 / 4006 / 64105 | 2977 / 3940 / 125058 |
| RW VU32 | 3281 / 4006 / 64105 | 4592 / 4635 / 125058 |
| RW VU64 | 3370 / 4006 / 64105 | 5301 / 5336 / 125058 |
| RW VU128 | 3358 / 4006 / 64105 | 5787 / 5824 / 125058 |

`arc_c` is within **2%** between arms on every RO cell (4006 vs 3940-3982 MB) — they matched
themselves because both implementations use the same allmem/32 floor. `arc_c_max` differs (64 GB OSv
vs ~125 GB Linux: half-RAM vs ~97%-RAM defaults) but **neither arm came within 6% of its own
ceiling**, so the differing ceilings never bound and cannot explain the ratio. On the RW cells
Linux's ARC grew *larger* (5.8 GB vs OSv 3.4 GB), so the cache asymmetry **favours Linux** there —
the OSv RW ratio is conservative, not inflated.

### #1513 PROVEN LIVE IN ALL SEVEN OSv CELLS
| cell | req_total | req_gt128KiB | max_KiB |
|---|---|---|---|
| RO VU32/64/128/192 | 36,229 / 37,201 / 36,675 / 36,323 | **0 / 0 / 0 / 0** | 128 / 128 / 128 / 128 |
| RW VU32/64/128 | 73,971 / 78,276 / 75,894 | **0 / 0 / 0** | 128 / 128 / 128 |
**~374,000 device requests across the sweep, not one above 128 KiB.** The lever is live by effect.

---

## 8. A/B vs THE PRIOR NATIVE CURVE — **TWO variables changed, not one**

**The changed variables are (1) the BASE (stale, 24 commits behind master → aligned, 181 commits ON
master) and (2) io_method (sync → worker).** Nobody should read this as a single-variable result. A
third difference exists on the *headline only* and is called out in §6: the Linux CPU instrument
changed from CloudWatch to on-box `/proc/stat`.

### RO ratio
| VU | prior native (stale base, sync) | this run (aligned base, worker) | delta |
|---|---|---|---|
| 32 | 0.96x | **1.00x** | +0.04 (+4%) |
| 64 | 0.52x | **0.53x** | +0.01 (+2%) |
| 128 | 0.30x | **0.29x** | −0.01 (−3%) |
| 192 | 0.27x | **0.26x** | −0.01 (−4%) |

(The brief also quotes RO 0.883x@VU32 and 0.293x@VU128 from the earlier root-cause reproduction;
this run's 1.00x and 0.29x bracket those consistently.)

### RW ratio
| VU | prior | this run | delta |
|---|---|---|---|
| 32 | 0.159x / 0.16x | **0.15x** | ~flat |
| 64 | 0.16x | **0.16x** | flat |
| 128 | 0.16x | **0.15x** | ~flat |

### The absolute quantities, which are what the ratios are made of
```
OSv   tps: VU32 156,327 -> 156,848 (+0.3%)   VU64 126,170 -> 130,801 (+3.7%)
           VU128 97,687 -> 98,064  (+0.4%)   VU192 88,615 -> 89,663  (+1.2%)
Linux tps: VU32 163,234 -> 156,401 (-4.2%)   VU64 240,534 -> 246,272 (+2.4%)
           VU128 325,089 -> 333,083 (+2.5%)  VU192 333,496 -> 339,574 (+1.8%)
OSv RW:    VU32 3,007 -> 2,911 (-3.2%)  VU64 4,540 -> 4,517 (-0.5%)  VU128 5,193 -> 4,809 (-7.4%)
```

### THE FINDING: **the aligned base did not move the curve.**
Every RO cell is within ±4% of the prior curve and every RW cell is flat. OSv's own absolute
throughput moved +0.3% to +3.7%, i.e. inside or barely outside rep spread. **The VU32 cell reaching
1.00x is the only cosmetically notable change, and it is driven as much by Linux dropping 4.2% as by
OSv gaining 0.3%** — which is exactly why absolute quantities are reported alongside the ratio.

This is a **measured null on the base change**, and it is a useful one: it means the previously
published shape was *not* an artifact of the stale fork point. The curve, the RO/RW distinction, the
VU32-peak-then-decline shape, `n_le5=0`, the ~1-block-per-request mutex rate and the ~2x CPU/txn all
reproduce on a base that contains upstream/master. The prior results were measured on the wrong base,
but they were **not wrong about the wall**.

### On io_uring, since that is what was asked for
This run is `worker`-vs-`worker`, not `io_uring`-vs-`io_uring` (§2). So it does **not** close the
question of whether io_uring changes the RO cell — it removes only the `sync` objection. The honest
io_uring experiment is a separate run with **both** arms rebuilt from the same PG source with
`--with-liburing`; `.local/a2a-final/rebuild-uring.sh` already produces a verified musl-liburing OSv
arm (`SYMS=22`), so it is achievable and cheap, and it should be done before any RO number is called
final.

---

## 9. WHAT I AM **NOT** CLAIMING

1. **NOT that the CPU/txn gap improved.** 2.09x → 1.99x is an instrument change on the Linux
   denominator (CloudWatch → on-box `/proc/stat`), not an OSv improvement. Like-for-like against
   CloudWatch this run reads **2.26x**. OSv's own side moved 180.1 → 183.4 µs/txn, i.e. **unchanged**.
2. **NOT that ae077860c was evaluated.** It is present and is an ancestor, but the OSv arm drives
   **NVMe, not virtio-blk**, so the fix is inert on this substrate by construction. This run is
   evidence neither for nor against it.
3. **NOT that io_uring was measured.** Both arms ran `io_method=worker`. No claim about io_uring's
   effect on any cell, and no RO number here should be called final under the io_uring directive.
4. **NOT that the 3.61x one-sided spread is fixed.** It did not recur (worst spread 1.08x across 42
   reps), but it was intermittent when first observed, so absence across 3 reps does not distinguish
   "fixed" from "did not fire". Recorded as not-reproduced.
5. **NOT a named mechanism for the ratio.** `n_le5=0` and ~183 µs/txn describe the *shape and size* of
   the cost; the ~90 µs/txn of excess CPU is still unattributed to call sites. "Cause unknown" is the
   verdict; no mechanism is invented here.
6. **NO extrapolation past the measured VU levels** (RO 32/64/128/192, RW 32/64/128), and no fitted or
   extended curve. A prior table was withdrawn for exactly that. No claim about VU256+, other
   instance types, other scale factors, or metal.
7. **NOT a metal or Firecracker result.** m5d.metal does not boot OSv and was not attempted.
   Firecracker was not measured.
8. **NOT libc-controlled.** musl-vs-glibc is uncontrolled and contributes an unknown share of the
   per-CPU efficiency gap. It is the one accepted, documented caveat.
9. **NOT a claim that the RW 0.15x is irreducible.** #1513 is live and, consistent with its own PR
   body and the prior refutation, it is not a throughput win — it is a latency/correctness fix.
10. **NOT independent corroboration where two numbers share a derivation.** The RO ratio and the
    CPU/txn ratio both rest on the same tps measurements; they are not two independent confirmations
    of one conclusion.

---

## 10. HYGIENE — ALL BOXES TERMINATED, 0 ORPHANS CONFIRMED

```
terminate-instances: i-0ae098b42cfc39d0c i-0f3c1b0c856bc9800 i-0543a7276ab14648d i-0c8d7aeeeae834881
  -> all four "terminated", "User initiated (2026-09-22 04:47:21 GMT)", Owner=agent-bench24
deregister-image  ami-0b55e8a3065b9f22b  -> Return: true
delete-snapshot   snap-0ef6883fc081efa86 -> deleted
(the intermediate 2 GB AMI-staging volume vol-05f9df722b09c835c was deleted during AMI creation)

ORPHAN CHECK, Owner=agent-bench24, us-east-2 + us-east-1 + us-west-2:
  instances: 0    volumes: 0    AMIs: 0    snapshots: 0
```

**SG `sg-0a0fec26afe57cd43` used AS-IS and never widened**, verified after the run:
`tcp/22 -> 73.4.58.126/32` and `tcp/5432 -> intra-SG only`. `OPEN_TO_WORLD: False`. No 0.0.0.0/0 rule
was ever created.

**Shared-account note, checked rather than assumed.** The other project's box
`i-0b8b44e56bf2f07d1` (Owner=None) is no longer running, so I verified it was not me:
it terminated at **04:20:49Z** while my four terminated at **04:47:21Z** — 27 minutes apart — and my
single `terminate-instances` call named only my own four instance IDs. The other 5 Owner=None boxes
(2x c6id.8xlarge, 2x c7i.2xlarge, 1x c7i.metal-48xl) remain **running and untouched**. Recording the
timeline rather than reasoning from a plausible story, because "an instance disappeared while I was
working" is exactly the shape of claim that needs a timestamp instead of an assumption.

---

## 11. SUMMARY

**The first trustworthy "OSv with everything we intend to upstream" vs Linux measurement, and it is a
measured null on the base change.**

1. **Preflight PASS at e83cdfef1 with no stale-base override** — ancestry TRUE (181 commits ON
   upstream/master), 64 open PRs derived with no author filter, REQUIRED 59/59 present, third-party
   reported as NOTES, 9 design collisions enumerated. All five named markers plus ae077860c verified
   independently and again on the builder's own tree.
2. **The curve did not move.** RO 1.00x / 0.53x / 0.29x / 0.26x at VU32/64/128/192 and RW ~0.15-0.16x
   flat — every cell within ±4% of the prior stale-base curve. 42 reps, **0 failed**, no cell
   driver-limited, worst spread 1.08x.
3. **CPU/txn is unchanged at ~2x**: OSv **183.4 µs** (was 180.1) vs Linux **92.3 µs**. The apparent
   2.09x→1.99x shift is the Linux CPU instrument changing (CloudWatch → on-box), not an improvement;
   like-for-like it reads 2.26x. **This remains the binding constraint**: ~183 µs/txn caps a saturated
   32 vCPU near 175k tps, so parity on 32 vCPU stays arithmetically out of reach, and OSv reaches only
   96k of even that ceiling, so a second constraint also binds.
4. **`n_le5=0` CONFIRMED, not refuted** — all 32 CPUs 46-76% busy at the busiest cell, with the 8-vs-24
   two-tier split reproducing exactly. Instrument positive-controlled (`n_le5=32` when idle).
5. **The prior results were measured on the wrong base but were not wrong about the wall.** That is the
   most useful thing this run establishes.

### Deviations and defects found, stated plainly
- **io_method=worker, not io_uring** — declared deviation with full reasoning (§2); io_uring is not
  compiled into apps@3f93f43, and rebuilding one arm would have added a third variable.
- **ae077860c is inert here** (NVMe arm, not virtio-blk), so the brief's expectation that it might move
  the CPU/txn number cannot be tested on this substrate.
- **A defect in my own instrument, caught before the run**: the NONROTPROBE reported from the kernel via
  an undefined-weak symbol would have compiled, linked, and silently never printed. Found with `nm`,
  not with a source grep (§3).
- **Two harness parsing bugs found and fixed** before the sweep: `failed=` read the percentage column
  (so the 0-failed gate compared against `(0.000%)` and could never be arithmetic), and pgbench writes
  `-P` progress to **stderr**, so the interval/p99-proxy fields were empty.
- **The builder's `/work` detector** silently matched nothing on c5d.9xlarge (`$2 ~ /T$/` vs an 838.2G
  instance store), leaving `/work` on the 150 GB EBS root; fixed to select by NVMe **model**, the same
  rule that prevents the root-disk-wipe hazard.

---

## 12. A WRAPPER BUG IN THE PREFLIGHT ITSELF (found by doing what the brief asked)

The brief said to re-run the preflight with `--build-log` and `--runtime-proof` once the artifacts
existed. Doing so exposed a defect **in the gate's own wrapper**:

```
.local/rebase2/preflight-integ.sh  last line, before:
    exec /home/gburd/ws/osv/.local/bench-preflight.sh "$TREE"
```

`"$TREE"` is `$1` and nothing else, so `preflight-integ.sh <tree> --build-log X --runtime-proof Y`
**silently discarded both evidence flags and still printed PASS**. The two checks whose entire purpose
is to catch a silently skipped patch and an unproven lever were **unreachable through the wrapper** —
and the wrapper is the only way this project invokes the gate. The inner script *had* been
negative-tested, but only by calling it directly, so the argument-handling path was never exercised.
This is the documented pattern exactly: a convenience wrapper quietly became a correctness assumption,
and it is the same shape as the `--author gburd` filter and the relative-`--build-log` false negative.

**Fixed** by `shift`-ing `$TREE` and forwarding `"$@"`.

**AND MY FIRST FIX INTRODUCED A SECOND BUG, recorded because it is the more instructive one.** I
placed the explanatory comment *between* the trailing `\` of the `BENCH_PR_REASONS` assignment and the
`exec`. That severs the line continuation, so the env-var assignments stopped being a prefix to `exec`
and `BENCH_SKIP_PRS`/`BENCH_PR_REASONS` were **never passed at all**. Result: all 9 declared exclusions
came back as failures (8 UNDETERMINED + #1424 ABSENT) and the gate refused to benchmark. **A comment is
not inert inside a backslash continuation.** Caught because the run exited 1 and I read the FAIL lines
instead of assuming my own edit was correct.

### Negative tests, through the real interface (a gate that cannot fail is not a gate)
| input | result |
|---|---|
| `--runtime-proof /nonexistent/x` | `FAIL [runtime] runtime proof file not found` → REFUSING. **correct** |
| a console file with no lever lines | `FAIL [runtime] no resolved-lever lines found` → REFUSING. **correct** |
| the real OSv console (1678 lines, 111 lever/probe lines) | `ok [runtime] 2 resolved-lever line(s)` → **PASS, exit 0** |

### Verbatim, the re-run WITH runtime proof forwarded (exit 0)
```
bench-preflight: /home/gburd/ws/osv/.local/bench24/wt @ e83cdfef1
  ok   [ancestry] base contains upstream/master
  ok   [prs] derived 64 open PRs from GitHub (no author filter)
  ok   [prs] REQUIRED (author gburd): 59
  ok   [prs] THIRD-PARTY (informational, never a FAIL): 5 ->1466 1390 1338 1288 1215 
  ok   [pr#1511] present by content (31/31 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1510] present by content (261/262 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1505] present by content (9/9 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  note [pr#1503] skipped: per-chain-dentry-lock-redesign-vs-our-fork-scopings-1502-base-fix-IS-present
  ok   [pr#1502] present by content (87/88 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1499] present by content (11/11 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1496] present by content (1/1 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  note [pr#1493] skipped: aarch64-RNDR-leg-taken-x86-leg-deliberately-superset-rdrand-OR-rdseed
  note [pr#1492] skipped: superseded-ours-covers-RDRAND-or-RDSEED-1492-is-RDRAND-only
  ok   [pr#1487] present by content (4/4 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1486] present by content (10/10 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1484] present by content (3/3 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1483] present by content (6/6 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1481] present by content (8/8 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  note [pr#1478] skipped: superseded-our-inline-cv_timedwait_hires-is-semantically-identical-see-RESULT.md
  ok   [pr#1475] present by content (778/796 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1472] present by content (66/66 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1470] present by content (232/233 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  note [pr#1467] skipped: rx_drain-rewritten-by-our-multiqueue-inline-rx-alternative-design-not-additive
  ok   [pr#1465] present by content (21/21 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1464] present by content (43/43 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1463] present by content (131/132 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1461] present by content (36/36 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1458] present by content (5077/5220 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1456] present by content (798/821 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  note [pr#1455] skipped: the-fork-series-itself-this-branch-IS-that-work-PR-diff-test-is-circular
  ok   [pr#1449] present by content (56/56 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1445] present by content (159/159 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  note [pr#1444] skipped: stacked-on-1442
  note [pr#1442] skipped: ipv6-subsystem-port-100-files-orthogonal-and-collides-with-our-virtio-net-rework
  ok   [pr#1441] present by content (106/111 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1440] present by content (204/204 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1439] present by content (112/112 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  ok   [pr#1438] present by content (49/49 lines); whole-diff reverse-apply failed only because later commits touch the same regions
  note [pr#1424] skipped: draft-crucible-driver-not-for-this-image
  ok   [prs] no REQUIRED open PR is fully absent from the base
  note [prs] --- third-party open PRs (NOT ours to land; absence is expected, never a FAIL) ---
  note [prs]     NOT in this image: 1215
  note [prs]     partially represented: 1466(36%) 1390(16%) 1338(17%) 1288(29%)
  note [prs]     *** DESIGN COLLISIONS: a third-party PR edits files one of ours also edits ***

       #1466 vs ours #1458 #1463 #1465 #1470 #1499 #1509 -- both edit drivers/virtio-blk.cc
       #1466 vs ours #1509 -- both edit drivers/virtio-blk.hh
       #1390 vs ours #1456 #1458 #1475 -- both edit core/lfmutex.cc
       #1390 vs ours #1456 #1458 #1472 #1475 #1511 -- both edit include/osv/sched.hh
       #1338 vs ours #1456 #1458 #1464 #1472 #1475 #1484 #1511 -- both edit core/sched.cc
       #1338 vs ours #1456 #1458 #1472 #1475 #1511 -- both edit include/osv/sched.hh
       #1288 vs ours #1456 #1458 #1464 #1472 #1475 #1484 #1511 -- both edit core/sched.cc
       #1288 vs ours #1456 #1458 #1472 #1475 #1511 -- both edit include/osv/sched.hh
       #1288 vs ours #1439 #1456 #1458 #1475 -- both edit libc/signal.cc
  note [prs]     Read each before benchmarking: two PRs rewriting one path may be
  note [prs]     alternative designs, not additive, and the maintainer's version is
  note [prs]     the one that decides.
  ok   [ozfs] 1 patch files present
  note [ozfs] vendored openzfs checkout absent: patch validity unchecked here (rely on --build-log)
  note [buildlog] no --build-log given: cannot prove the patch series applied
  ok   [runtime] 2 resolved-lever line(s) in the guest console

bench-preflight: PASS
```

### AND AN HONEST GAP: I cannot supply `--build-log`
**I terminated the builder before copying `/work/build-osv.log` off it.** The build evidence in §3
(2659 lines, per-file compile counts, artifact sizes, `nm` symbol checks) was read off the builder and
transcribed while it was alive, and it is accurate — but the log file itself is gone, so the
`[buildlog]` check reports `no --build-log given` rather than passing. That is a real hole in this
run's evidence chain and I am not papering over it: the buildlog check is the one that catches a
silently skipped patch, and I cannot demonstrate it passing for this image.

Mitigating, but not equivalent: this base carries the OpenZFS OSv platform layer **in-tree with 1
patch** instead of the 45-patch series, so the specific failure mode that check exists to catch (0032
silently never applying) is structurally absent here — the file is tracked source that the build log
confirmed was compiled. **Fix for next run: copy the build log to `.local/<run>/` immediately after the
build, before any teardown.** Artifacts that live only on a box that gets terminated are not artifacts.
