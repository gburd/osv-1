# PostgreSQL-on-OSv milestones

Local steering doc. Not tracked.

## M1 - apples-to-apples parity with Linux: ACHIEVED

OSv/PG on ZFS + local NVMe now beats Linux/PG on the same workload at peak.

- Workload: HammerDB TPROC-C, 40 warehouses, rampup 1min + duration 3min,
  bare-metal KVM host, ZFS on local NVMe, identical pool geometry on both sides.
  Full runbook: `.local/HAMMERDB-BENCHMARK.md`.
- Linux baseline (PG16 on ZFS): VU8 = 38948 NOPM.
- OSv (v19 fix stack, PG18-musl on OpenZFS): VU1 = 19688, VU2 = 33226,
  VU4 = 49020, VU8 = 67558, VU16 = 67568 (peak, ~1.73x Linux VU8), VU32 = 44929.
- All OSv runs crash-free.

Peak OSv throughput (VU16) is about 1.73x the Linux VU8 baseline. M1 (fair
parity) is met and then some: OSv is ahead at peak, not merely level.

What it took: the 10-commit fork/mmap/ZFS coherence stack on
`wip/pg-zfs-bench-v19`, fixing three cross-address-space coherence root causes
under OSv's copy-on-write fork emulation:
1. vma-range / ELF bookkeeping on the identity heap.
2. child thread / detached_state / lazy_indirect backing on the identity heap
   (plus wake-path hardening for stale/torn thread pointers).
3. OpenZFS ARC-eviction waiter on the identity heap (patch 0030).

## STATUS UPDATE (2026-08-31): the VU32+ investigation is CLOSED

The fold-back past VU16/32 was NOT guest-CPU saturation. It was a scheduler
load-dispersal failure: past the vCPU count, woken backends piled onto ~8-10
vCPUs while the rest halted. Fixed by arming OSV_WAKE_PULL (idle-CPU pull,
PR #1472): +238% at VU64, +243% at VU96, +238% at VU128 on HammerDB TPROC-C.
Peak measured ~248k NOPM at VU32 on a 32-vCPU guest; Firecracker peaked at
145k NOPM at VU16 (16-vCPU), 2.9x the Linux VU8 baseline at VU8.

Also closed: the high-VU crash walls. EMFILE (fd table, PR #1485), the
autovacuum/checkpoint reclaimer OOM (PR #1487 synchronous ARC shrinker +
retry-reclaim), and the callout use-after-free (PR #1486) are all fixed, so
PG-on-OSv-ZFS is crash-free through VU192 (autovacuum off) and VU128
(autovacuum ON, the production setting). Beyond that it degrades in throughput
(fragmentation) rather than crashing.

Second ISA: aarch64 (Graviton3 bare metal) now builds, boots under KVM, and
SERVES queries -- pgbench on ZFS 2190 tps, 0 failed (branch
wip/aarch64-forkcow-signed). Not yet VU-swept (a >=4 GB temporary-phys-map bug
caps the guest at 3 GB).

Hugepages: measured, no meaningful effect on this WAL/lock-bound workload.
p99: measured throughout; it is the least-TUNED axis (see
PG-ON-OSV-TUNING.md sec 11).

## Original open list (historical)

Parity is proven at the tested scale, but the OSv curve folds back at VU32
(44929 NOPM, below the VU16 peak). This is attributed to 8-vCPU guest CPU
contention (TPROC-C saturates the guest CPUs past ~2x oversubscription), not a
correctness problem. Still to do:
- Scale the VU sweep to VU192 on larger (more-vCPU) guests to find OSv's real
  peak rather than the 8-vCPU saturation point.
- Firecracker on arm (aarch64) for the micro-VM path and a second ISA.
- Hugepages on vs off, to measure the TLB effect on the fork/mmap-heavy path.
- p99 latency, not just NOPM throughput.
