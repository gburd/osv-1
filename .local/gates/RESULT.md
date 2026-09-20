# Gates run — adaptive-idle-spin: two gates + a NEW distinct VU64 residual (2026-09-18)

Owner=agent-gates. Account hotdog 585335547908, us-east-2a. Base gh-fork/bank/sched-adaptive-idle-spin
@ 1685b6511 (adaptive-v2), apps @ 3f93f43. bench-base-gate PASS all 9 markers + adaptive-fix markers.

## BOX IDs (terminated at end — see housekeeping)
- METAL  i-07cd70356cef08c3a  m5d.metal (Debian 12, ami-0dc1629a58a7d6458) — OSv + Ubuntu guests + host + instr
- DRV    i-0d81859ea71589291  c5.4xlarge (Ubuntu 24.04) — HammerDB 6.0 driver

## io_uring — CONFIRMED ACTIVE BOTH ARMS
Base OSv PG build had with_liburing=no; REBUILT: musl liburing 2.5 (--use-libc + -idirafter /usr/include
for uapi headers) + PG --with-liburing (22 io_uring symbols, WITH_LIBURING=1, configure "yes"), liburing.so
shipped, image 119209984 B. OSv PG boots "ready to accept connections" with -c io_method=io_uring; both
OSv and Linux `show io_method` => io_uring.

================================================================================
## GATE 1 — idle-regression A/B : **PASS (decisive)**
================================================================================
Mostly-idle OSv guest (200wh PG up, 4 idle pg_sleep connections, quiesced). Host CPU consumed by the qemu
process measured from /proc/<qemu-pid>/stat utime+stime jiffies over a fixed wall window (CLK_TCK=100) —
a REAL host counter, not a guest guess. Fresh boot per arm. Spin lever confirmed from the boot console.

| arm         | rep | window_s | cpu_core_seconds | pct_of_one_core |
|-------------|-----|----------|------------------|-----------------|
| adaptive-v2 | r1  | 120.00   | 24.520           | **20.43%**      |
| adaptive-v2 | r2  |  90.01   | 18.540           | **20.60%**      |
| fixed-10000 | r1  | 120.00   | 77.540           | **64.62%**      |
| fixed-10000 | r2  |  90.01   | 56.180           | **62.42%**      |

adaptive-v2 median ~20.5% vs fixed-10000 ~63.5% of one core — adaptive burns ~1/3 the idle CPU. The gate
required adaptive <= fixed + small margin; adaptive is dramatically better (it shrinks the window to the
floor after consecutive halts and halts, instead of spinning the fixed 10000 every idle entry).
=> On the idle-cost axis, adaptive-idle-spin is SAFE TO PROMOTE DEFAULT-ON.

================================================================================
## GATE 2 — a2a gold test (VU32 low-mode + VU32->192 scaling vs matched Linux)
================================================================================
Fresh-boot-per-cell, io_uring both, matched Linux (same m5d.metal, same raw /dev/nvme1n1 ZFS pool
ashift=12/recordsize=8k/sync=standard, 32GiB ARC, same 200wh/19GB schema). One caveat: libc (OSv musl /
Linux glibc), the least-central variable — ZFS+io_uring+HW+NVMe+ARC all matched.

### VU32 — OSv adaptive-v2 (MEASURED NOPM, fresh-boot-per-cell)
| rep | NOPM   | qemu-cpu discriminator (pct-of-one-core; 3200=32 vCPU) | verdict |
|-----|--------|--------------------------------------------------------|---------|
| r1  | 246458 | during_run_median 2296 (n_hi=99) | healthy, CPU-saturated |
| r2  | 229755 | during_run_median 2305           | healthy, CPU-saturated |
| r3  | 186862 | during_run_median 2282           | healthy, CPU-saturated |
| r5  | 180014 | during_run_median 2260           | healthy, CPU-saturated |
| r4  | VOID   | HammerDB-6.0 gather-hang (VUCOMPLETE_AFTER 360s, NVMe=0, no TEST RESULT, Tcl exit err) — harness artifact (a2a hit the same), NOT the OSv low-mode |

OSv adaptive VU32 median (4 healthy reps) = **208,309 NOPM**. **All 4 healthy reps CPU-saturated (~23 of
32 vCPU); NONE fell into the 0.5-vCPU-waiting low-mode.** The prior a2a saw an intermittent 93k low-mode
rep (0.5 vCPU + waiting) at VU32; here, across 4 adaptive reps, no such waiting-mode appeared — the qemu-
cpu discriminator was CPU-saturated on every healthy rep.

HONESTY on the VU32 low-mode-cured claim: the decisive fixed-vs-adaptive VU32 A/B (fixed-10000 reproducing
the low-mode HERE while adaptive does not) was NOT completed — the run was landed before that sweep
finished (9h on a shared billed account). So the VU32 result is stated as: **adaptive-v2 VU32 is CLEAN
across 4 healthy reps (no idle->wake low-mode observed), CPU-saturated throughout** — consistent with the
fix curing the idle->wake residual, but the A/B-proof-by-contrast is not in hand. Not overclaimed.

### VU32 / VU64 — matched Linux (MEASURED NOPM, same stack)
| VU | Linux NOPM | 6-min xact_commit sampling |
|----|-----------|----------------------------|
| 32 | 338265    | sustained ~200-235k commits/15s, CPU-saturated, no wedge |
| 64 | 486112    | sustained ~280-370k commits/15s for full 6 min, CPU-saturated 22-27 vCPU, NO wedge |

OSv/Linux ratio at VU32 = 208309/338265 = **0.62** (OSv trails; a2a had 0.72 fresh-boot — my Linux ran
warm-cache-continuous here so its VU32 is higher than the a2a's 284k fresh-boot number).

================================================================================
## VU64 — A NEW, DISTINCT, OSv-SPECIFIC, PERMANENT LOST-WAKEUP DEADLOCK (the finding)
================================================================================
At VU64 (untested before — the prior a2a stopped at VU32), OSv hits a hard wedge. Fully characterized
with four discriminators, all MEASURED:

**(a) TRUE DEADLOCK, not a slow stall.** Run starts HEALTHY ~60s (~110-116k xact_commit/15s, NVMe 58-97%,
qemu 2075-2208% = CPU-saturated), then FALLS OFF A CLIFF at t~75s to xact_commit_delta=2 per 15s (just
autovacuum/checkpointer housekeeping), NVMe=0.00, qemu ~45-49% of one core (IDLE, not spinning). Stays
there the full remaining ~5 min (t=75 -> t=360). **NEVER recovers.**

**(b) NOT io_uring-specific.** io_method=io_uring wedges (WALWrite waiters pileup=65, NVMe=0, idle). io_
method=WORKER wedges IDENTICALLY (waiters=5 — blocks at IO-worker submit — same outcome: commit_delta=2,
NVMe=0, idle, never recovers). => The lost wake is NOT in core/io_uring.cc. Both io_methods funnel through
the same ZFS-ZIL / WAL-commit sync-write completion -> waiter wakeup, which is where the wake is lost.

**(c) NOT caused by adaptive-idle-spin.** OSV_IDLE_SPIN_ADAPTIVE=0 (fixed-10000) ALSO wedges at VU64
(healthy through ~t=75s, then PG unreachable, qemu 4s jiffies delta=0 = fully idle, never recovers). =>
Pre-existing ceiling, not a regression from adaptive spin or the leak fixes. Both configs wedge identically.

**(d) OSv-SPECIFIC.** Linux on the IDENTICAL stack (same m5d.metal, same raw /dev/nvme1n1 ZFS pool, same
io_uring, same 200wh schema) SCALES to 486112 NOPM at VU64, sustaining ~280-370k commits/15s for the full
6 min, CPU-saturated (22-27 vCPU), real IO throughout, WALWrite waiters oscillating 3-62 (normal
contention, no stuck pileup). NO wedge. => Not a PG/ZFS-on-this-hardware ceiling; it is OSv's cross-vCPU
wakeup deficit at the completion->waiter layer.

### WEDGE SIGNATURE (for the next root-cause run)
- pg_stat_activity at wedge: ~66 of 69 active backends on **LWLock/WALWrite** (io_uring) or ~5 on WALWrite
  + rest at IO-worker submit (worker); **checkpointer in IPC/CheckpointDelayStart**; **background writer
  in Activity/BgwriterHibernate**; running queries are neword/payment/delivery prepares + autovacuum.
- Host discriminators at wedge: **NVMe /dev/nvme1n1 %util = 0.00, 0 wkB/s** (zero disk IO); **qemu host
  CPU ~0.3-0.5 vCPU** (idle, not spinning — 5s jiffies delta ~166, i.e. the guest is WAITING).
- Transition: healthy ~60s (real commits + IO + CPU-saturation) -> cliff at t~75s -> permanent (never
  recovers over 5 min).
- Path pointer: the WAL-commit / ZFS-ZIL sync-write COMPLETION -> waiter wakeup (a fsync/zil_commit whose
  completion wakeup is lost cross-vCPU, so the WAL writer sleeps without releasing WALWrite and every
  committer piles up behind it; zero IO + idle CPU confirm nothing is in flight). Both io_uring and worker
  reach it, so look at the ZIL commit completion / zio-done -> cv_broadcast/wakeup path and the cross-vCPU
  IPI-to-halted-vCPU delivery on that wake, NOT core/io_uring.cc. Likely same class as the OSV_IDLE_SPIN
  residual but at the completion->waiter layer rather than idle->wake.

================================================================================
## HONEST VERDICT
================================================================================
adaptive-idle-spin v2 is a REAL, MEASURED **PARTIAL** win:
- GATE 1 PASS: idle-safe — 20.5% vs 63.5% of one core idle CPU (host counter). Promotable DEFAULT-ON.
- GATE 2 VU32: clean — 4 healthy CPU-saturated reps (median 208k NOPM), no idle->wake low-mode observed.
  (The fixed-vs-adaptive VU32 A/B proof-by-contrast was not completed before landing — stated honestly.)

It does **NOT**, and structurally **cannot**, fix the VU64 wedge: that is a SEPARATE, OSv-SPECIFIC,
PERMANENT lost-wakeup **deadlock** on the WAL-commit/ZIL-completion->waiter path — a DIFFERENT layer
(completion->waiter) than the idle->wake window adaptive-idle-spin controls. It is very likely PRE-EXISTING
(VU64 was never tested; the a2a stopped at VU32) and Linux on the identical stack does not have it.

NOT CLAIMED: "residual fixed" (VU64 refutes the blanket version), "parity at VU64+" (OSv wedges; Linux
scales to 486k). Two honest findings: the fix works for what it targets (idle->wake + idle-safety), and a
new deeper residual (VU64 ZIL-completion lost-wakeup deadlock) is the next named target.

## Fix status
adaptive-idle-spin stands on GATE 1 + VU32, on bank/sched-adaptive-idle-spin @ 1685b6511 as-is. The
master-rebase (bank/sched-adaptive-idle-spin-master) + PR were NOT prepped in this run (landed to save box
time; the delegating agent handles master-rebase + PR-open separately). Supporting data: GATE1-RESULT.md,
GATE2-DATA.md, cells/VU64-WEDGE-evidence.txt, cells/wedge-*.txt, cells/SWEEP-*.log, cells/osv-vu32-r*.*.
