# a2a-final methodology note (2026-09-17)

## io_uring build gap + resolution (agent 2da3e1c8)
The OSv PG18.6 build (apps 3f93f43) was configured WITHOUT --with-liburing, so io_method=io_uring is
REJECTED at boot ("Available: sync, worker"). The operator directive mandates io_uring BOTH sides (not
worker) for perf tests. RESOLUTION: rebuild OSv PG with --with-liburing + ship liburing.so, then io_uring
both sides. VERIFIED (main agent): OSv's core/io_uring.cc is a REAL 40-opcode implementation including
READ/READV/READ_FIXED, WRITE/WRITEV/WRITE_FIXED, FSYNC - the ops PG's AIO path uses. So the rebuild is
sound.

Guardrails steered:
1. SMOKE-TEST io_uring at runtime (PG starts + a write+fsync workload completes + no errors/hang/silent
   sync-fallback) BEFORE committing the sweep to it - tst-io_uring passing is necessary not sufficient
   since PG drives it differently.
2. If io_uring works -> both sides (the goal). If broken for PG -> fall back to io_method=worker MATCHED
   both sides (NEVER sync-vs-io_uring or io_uring-vs-worker); report the deviation + why. Whichever,
   state the AIO method prominently with the curve.

Seed verified: ZFS on raw /dev/nvme1n1 passthrough, 52M cluster, all levers ON (WAKE_PULL, MQ per-queue=8).
Fresh-boot-per-cell, do NOT void the fresh r1, capture p99, VU8/16/32/64 each own boot both sides.

## EARLY RESULTS (2026-09-17, OSv arm, fresh-boot io_uring all-fixes):
io_uring REBUILD + smoke WORKS (real result: OSv io_uring viable for PG). OSv curve so far:
  VU8  median 74,332  (p99 ~7-18ms)
  VU16 median 171,502 (+131% from VU8 = SCALES; the OPPOSITE of the contaminated declining curve)
  VU32 286453/231651/93710 -> median 231,651 (still >VU16 = STILL SCALING; NO dentry wedge, #1502 holds)
THE HEADLINE (qualitative): the "OSv declines VU8->16->32" SHAPE IS GONE once fresh-boot + all fixes are
in. OSv SCALES VU8->VU16->VU32. Consistent with the run-order-artifact reframe + the two leak fixes.
CAUTION: VU32 has a 3x spread. r3 (93710) instrumentation: qemu_cpu=56/3200 (~0.5 of ONE core across 32
vCPUs) + NVMe ~43% util = guest WAITING, not wedged/CPU-bound/IO-bound = the cross-vCPU WAKEUP-LATENCY
starvation signature (our known deficit) OR a shared-host transient. VU32 median is SOFT. Steered: 4th/5th
fresh-boot rep (do NOT void r3 - that bias made the old artifact), capture the qemu-cpu discriminator on
any low cell (low-cpu+low-tput = wakeup-latency; high-cpu = other), then VU64, then the MATCHED LINUX arm
(same metal/NVMe/ARC/musl-PG/io_uring, fresh-boot). Parity = OSv-median-vs-Linux-median at each VU on
identical HW - the OSv curve alone is only half.

## OSv ARM FIRMED + VU64 HARNESS INCIDENT (2026-09-17):
OSv fresh-boot io_uring all-fixes, FIRMED:
  VU8  med  74,332 (72277/86193/74332)
  VU16 med 171,502 (173022/171502/165372) +131%
  VU32 med 205,234 (5 reps: 286453/231651/93710/205234/195843 - 4 healthy 195-286k + 1 low 93k, KEPT)
CONFIRMED via qemu-cpu discriminator: the 93k VU32 low-rep = 56/3200 (0.5 vCPU) + 43% NVMe = guest WAITING
= cross-vCPU WAKEUP-LATENCY starvation (the known deficit, biting intermittently at VU32); healthy reps run
1350-1450/3200 (~14 vCPU) + 62-70% NVMe. r3 KEPT (not voided - avoids the artifact bias). SHAPE FLIPPED:
declining->scaling, #1502 holds (no dentry wedge). This is the headline: OSv SCALES once fresh-boot + all
fixes are in.
INCIDENT (VU64 r1 boot): PG PANIC 'could not locate a valid checkpoint record' + zfs mount abort = the
poweroff SIGKILLed qemu MID-CHECKPOINT (ssh-timeout race) on the sync=standard ZFS pool, tearing the
ZIL/mount. HARNESS bug, NOT an OSv fault. Pool rebuilding (~35min); poweroff hardened (checkpoint-to-
completion + fast-second-checkpoint + idle-check + settle, never kill mid-write). LESSON: never SIGKILL
qemu mid-CHECKPOINT on a sync=standard ZFS pool.
REPRIORITIZED (tight budget): pool rebuild -> MATCHED LINUX ARM VU8/16/32 FIRST (gives the parity verdict
at the levels where OSv medians are solid) -> VU64 both sides only if budget remains. Do NOT leave zero
Linux arm. Apply the qemu-cpu variance discriminator to Linux too (does OSv's low-mode have a Linux analog
= characterizes the residual wakeup deficit).
