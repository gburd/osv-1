# Linux/PG18 baseline: the LWLock:WALWrite question, answered

> **CORRECTION 2026-09-09: "no scaling region on Linux either" was a 16-vCPU SATURATION ARTIFACT.**
> On matched geometry (32 logical CPUs, bare metal, musl) Linux scales strongly:
>
>       VU8 232,139 | VU16 397,160 | VU32 527,415 | VU64 627,652 (PEAK) | VU96 581,061
>
> Peak at **VU64, 2.7x its own VU8 figure**. The old 16-vCPU VM reference peaked at VU8 and declined
> monotonically, and I generalised that shape into "PostgreSQL/TPROC-C has no scaling region on this
> workload, on any platform." **That was wrong.** The platforms differ in SHAPE, not only level:
> Linux converts added concurrency into throughput up to VU64; OSv converts it into queueing
> immediately (peaks at VU8 and declines). The gap therefore WIDENS with concurrency:
> 5.3x at VU8, 10.5x at VU16, 15.2x at VU32, 22.1x at VU64, 22.3x at VU96.



2026-09-08, agent c8742b2c. Boxes terminated, 0 orphans. PG **18.6** from `REL_18_STABLE`
with the OSv arms' exact configure line, `io_method=sync` matched, on ZFS-on-NVMe with
fsync/synchronous_commit/autovacuum ON, 200 warehouses (19 GB > 16 GB shared_buffers).

## The headline: same lock, opposite device state

|                     | OSv aarch64        | Linux (this run)          |
|---------------------|--------------------|---------------------------|
| `LWLock:WALWrite`   | 20-31 of 32 backends | **55.3 of 64 avg, peak 63/64** |
| NVMe `%util`        | **1.34-2.80% (IDLE)** | **73-93% (near-saturated)** |
| write rate          | -                  | pinned **257 MB/s**, aqu-sz 8-11 |
| CPU                 | idle               | 59.7% idle                |

**So `LWLock:WALWrite` dominating is NOT evidence of an OSv defect.** It reproduces on stock
Linux/glibc at matched PG version and `io_method`. PostgreSQL's WAL design serializes on any
platform; that part is settled and should not be chased as an OSv bug.

**But the discriminator is `%util`, not the lock name.** On Linux the queue is the expected
consequence of a device at 87-90% of its achievable ceiling. On OSv the identical queue
formed with the device **98% idle**. Same symptom, completely different cause. The OSv-side
cost is real and still worth chasing; what is now excluded is "PostgreSQL's WAL lock is an
OSv problem."

**Lesson for future diagnosis: a wait-event name alone does not discriminate. Always pair it
with device utilisation.** Had we not measured `%util` on both sides we would have drawn
exactly the wrong conclusion in either direction.

## Throughput: no scaling region on Linux either

| VU | median NOPM | spread | NOPM/vCPU |
|----|-------------|--------|-----------|
| 8  | **99,504**  | 3.7%   | 6219 |
| 16 | 96,528      | 14.3%  | 6033 |
| 32 | 86,241      | **34.9%** | 5390 |
| 64 | 75,247      | **30.3%** | 4703 |
| 96 | 81,080      | 10.1%  | 5068 |

Peak at VU8, declining after. NEWORD p50 scales linearly 1.6 -> 26.3 ms while throughput
falls: added concurrency buys queueing, not work. Driver 98.1% idle at VU64, so **all levels
are DB-limited, not driver-limited** (the agent checked, having flagged the risk in advance).

## A defect in MY mandated config, found by measurement

`checkpoint_timeout=15min` **never fires**: `num_timed=0`, and 49 of 51 checkpoints were
WAL-triggered, recycling 8.8 GB every ~72 s. So 4-5 checkpoints land in every 5-minute
window at arbitrary phase, which is the structural cause of the 30-35% spreads at VU32/64 -
not noise. Fix for the re-run: raise `max_wal_size` or lengthen `pg_duration`.

`write=73.3 s` vs `sync=3.68 s` (93% write) independently corroborates the OSv x86 arm:
**the write phase dominates and fsync is cheap.**

## Connect latency: OSv is ~65x worse, far outside any caveat
Linux: 4350 samples, **zero failures, zero >=1 s, worst 17.6 ms**, median 4.0-4.3 ms across
VU8-96. OSv aarch64: **262 ms median**. That gap dwarfs the musl-vs-glibc and geometry
confounds, so it is a genuine OSv fork/connect cost, not a measurement artifact.

## ZFS costs 3.9x on the WAL pattern
56.1 MB/s at 8 KiB `direct,dsync` through ZFS vs **218 MB/s** raw on the same device
(raw 1 MiB direct: 296 MB/s). **Splitting WAL onto `recordsize=1M, logbias=throughput` is the
obvious next lever** and applies to both platforms.

## Residual confounds, stated not buried
16-vCPU VM slice vs the OSv arms' 32-vCPU metal partition; glibc vs musl. Per-vCPU figures
given. **This run establishes the Linux reference; it is not the final OSv-vs-Linux
comparison.** The correct future matching is **Linux on m5d.metal with cores restricted**,
not OSv on a VM slice, because OSv needs /dev/kvm and only metal types provide it.

## Two things the agent flagged against itself
- `io_method=worker` series NOT run (budget). The gap it would quantify - what finishing
  OSv's AIO path is worth - remains open.
- Its `probe.py` scp silently failed to replace the predecessor's script; it read the
  existing one, confirmed functional equivalence to the mandate, and adapted the parser
  rather than re-running. **Flagged rather than buried**, which is the right call.
- Also found: `pg_hba.conf` had **no rule for 172.31/16**, so the driver could never have
  authenticated - plausibly the cause of the predecessor's 19-hour stall.
