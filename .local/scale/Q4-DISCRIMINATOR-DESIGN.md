# #4 THE VU32 DISTINCT FACTOR - discriminator design (what each outcome PROVES)

## What is already RULED OUT (with a mechanism, not a null)
Memory pressure / the fork footprint. The footprint study measured +0.4% with the fix AND
ovflive_MB=0 in BOTH arms at 32 clients => the overflow path is NEVER ENTERED at VU32, so
there was no pressure to relieve. The ~0.62-0.72x VU32 median gap is therefore a DISTINCT
throughput factor.

## THE DISCRIMINATOR (the cheap decisive one, per the brief)
Run a matched OSv-vs-Linux VU32 cell with durability REMOVED (fsync=off +
synchronous_commit=off) alongside the normal durable VU32 cells. Everything else identical
(same box, same image, same ZFS geometry, same io_uring, fresh boot, same driver).

Define:
  R_dur    = OSv_NOPM_durable    / Linux_NOPM_durable     (expect ~0.62-0.72 from the a2a)
  R_nondur = OSv_NOPM_nondurable / Linux_NOPM_nondurable

### Outcome A -- the gap VANISHES without durable writes (R_nondur ~ 1.0, R_dur ~ 0.7)
=> The factor lives in the DURABLE COMMIT PATH: ZIL/WAL commit, i.e. the per-commit
   recycle-latency deficit this campaign already named (OSv ~1.5 vs Linux ~13 lwbs in
   flight). The gap is NOT general CPU path length, because with the same code, same
   syscalls and same query volume minus durability, OSv keeps up.
   Named factor: OSv ZIL commit concurrency / per-commit wake-and-recycle latency.

### Outcome B -- the gap PERSISTS without durable writes (R_nondur ~ R_dur ~ 0.7)
=> It is NOT the commit path; it is a GENERAL per-transaction cost. Then split it with the
   HOST qemu-cpu counter, which is not a guest guess:
     B1. OSv qemu-cpu ~= Linux qemu-cpu (both CPU-saturated) but OSv does FEWER tx
         => OSv burns MORE CYCLES PER TRANSACTION: a path-length/efficiency gap
            (syscall path, scheduler overhead, TLB/page-fault churn, lock contention).
         Next probe: cycles-per-tx = qemu_cpu_seconds / transactions, both arms; then
         profile where they go.
     B2. OSv qemu-cpu MUCH LOWER than Linux's, with NVMe not saturated
         => OSv is WAITING, not computing: a latency/blocking gap. Then the wait_event
            histogram in pg_stat_activity names what it waits on, and the comparison is
            against the same wait on Linux.

### Outcome C -- OSv is FASTER nondurable but Linux barely moves
=> Linux was not durability-bound at VU32 in the first place while OSv was; same
   conclusion as A but stated from the other side, and worth reporting explicitly since
   it changes WHERE the fix has to go.

## WHY THIS IS HONEST
Both arms get the SAME non-durable treatment, so it is a matched A/B of a REMOVED
variable, not an OSv-only concession. fsync=off + synchronous_commit=off is not a
production setting and is not reported as a throughput result -- it is used ONLY as a
mechanism discriminator, and reported as such.

## SUPPORTING MEASUREMENTS captured on every VU32 cell anyway
- qemu-cpu median (host counter) -> CPU-saturated vs waiting, per rep.
- NVMe %util / w_await / aqu-sz on the arm's own device -> is the device the limit.
- pg_stat_activity wait_event histogram -> what PG itself thinks it waits on.
- NEWORD p99 -> whether the gap is tail-latency or throughput-shaped.
- driver CPU + NIC -> proves the client is not the limit (else the cell is invalid).
