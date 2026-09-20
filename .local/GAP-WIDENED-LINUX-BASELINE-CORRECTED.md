# The Linux baseline was understating Linux by ~2x. The gap is 5.3x / 11.5x, not 2.3x / 4.9x.

2026-09-08, agent 7d0737f3 Task C. **The most important measurement of the campaign, and the
direction is unwelcome - which is exactly why it is published unsoftened.**

## The correction

    old Linux ref (16 vCPU VM, glibc)      99,504 NOPM @ VU8
    new Linux (32 logical metal, musl)    232,139 NOPM @ VU8   = 2.33x higher

    OSv x86_64   43,407  ->  was 2.3x below Linux,  NOW  5.3x below
    OSv aarch64  20,121  ->  was 4.9x below Linux,  NOW 11.5x below

**Removing the confounds did NOT flatter OSv.** Every "OSv is 2.3x behind" statement in this project
was measured against a handicapped baseline: a 16-vCPU VM with glibc, against OSv guests on 32-vCPU
bare metal with musl.

## Why 2.33x is credible rather than an outlier
2x the CPU alone predicts ~199k; measured 232k is a further **1.17x**, attributable to bare metal
instead of a VM plus a faster local NVMe path. Roughly linear in CPU with a modest metal bonus -
exactly the expected shape.

## The sentence that makes it bulletproof
The agent's ARC cap **binds hard**: `size` 17,224,108,416 against `c_max` 17,179,869,184, pinned at
the 16 GiB ceiling all run. The **OSv guest's ARC is ~32 GiB** (patch 0031 caps it at half of a
64 GiB guest). So:

**Linux ran with HALF the cache OSv had and was still 5.3x faster.**

The one remaining asymmetry in the comparison **disfavours Linux**, so the gap is if anything
understated. That pre-empts the most obvious objection to the entire result.

## Every binding proof was taken UNDER LOAD, not at configuration time
- **cpuset binds**: CPUs 0-15,48-63 at ~74% busy (51 usr / 21 sys / 25 idle), every other CPU idle.
- **ARC binds**: pinned at the ceiling throughout, occasionally ~40 MB over.
- **memory.max does NOT bind**: `memory.peak` 19,147,239,424 (17.8 GiB) vs a 64 GiB ceiling - as
  predicted. Honest framing: **geometry matched, memory not the binding constraint on either side.**
- **Device genuinely working**: 14.8-16.9k w/s, **304-414 MB/s** writes, %util 37.6-46.6, aqu-sz ~2.
- **Normal TPROC-C mix**: NOPM/TPM = 0.434. Not a cached or degenerate run.
- Durability verified externally from the driver: fsync=on, synchronous_commit=on,
  full_page_writes=on, wal_sync_method=fdatasync, io_method=sync, max_wal_size=65536MB.
- Data really on ZFS: `pgdata on /data/pg type zfs`, pool alloc 59.3G, 200 warehouses / 19 GB /
  order_line 59,998,209 rows.

## The bottleneck matrix is now complete, and %util is still the discriminator

    Linux (32 logical metal, musl)  LWLock:WALWrite 1-4 of 32    device ~40% busy   healthy
    OSv x86 VU32                    WALWrite 1-5 of 32           device 15.7%       UNATTRIBUTED STALL
    OSv x86 VU96                    WALWrite 32-85 backends      device 93% idle    OSv-side serialization
    OSv aarch64 VU32                WALWrite 31 of 34            device ~0-2%       OSv-side serialization
    Linux (old 16 vCPU VM)          WALWrite 55 of 64            device 73-93% busy PG WAL design

Linux at moderate concurrency has **neither** a WAL-lock queue **nor** an idle device. With wait
events alone, four of these five rows would be misread as "a WAL problem".

## What this does to the north star
**M1 parity is much further away than we believed.** The honest statement is that OSv is **5.3x
behind on x86 and 11.5x behind on aarch64** under a properly matched production-shaped comparison,
with the remaining asymmetry favouring OSv. Every prior gap figure in this project's docs should be
read as against the old handicapped baseline.

Still one run at VU8 r1 - the 3 repeats and the rest of the sweep are pending, and this number is now
load-bearing for the project headline, so it needs its repeats before it is quoted as final.

## SECOND FINDING, larger than the first: the gap WIDENS with concurrency (5.3x -> 22.3x)

The "no scaling region on Linux either" conclusion was a **16-vCPU saturation artifact**. On matched
geometry Linux scales strongly:

     VU  Linux(metal,musl)   OSv x86    ratio
      8         232,139       43,407      5.3x
     16         397,160       37,690     10.5x
     32         527,415       34,789     15.2x
     64         627,652       28,377     22.1x   <- Linux PEAK, 2.7x its own VU8
     96         581,061       26,047     22.3x

**So the headline is not a single ratio.** It is 5.3x at VU8 rising monotonically to 22.3x at VU96,
and the platforms differ in **SHAPE**, not only level:
- **Linux converts added concurrency into throughput** up to VU64.
- **OSv converts it into queueing immediately** - peaks at VU8 and declines monotonically.

That is a qualitatively different failure mode from "slower", and it points at the fork/connect path
and the WALWrite-on-idle-device serialization rather than at raw per-operation cost.

For scale: **Linux's VU64 peak sits beyond the point where OSv aarch64 stops functioning at all**
(it could not complete VU32), and OSv x86 reached VU96 only while declining throughout.

## My error, and it was the same mistake one level up
I banked "no scaling region on Linux either" into **three** documents
(`LINUX-BASELINE-VERDICT.md`, `CAMPAIGN2-LAUNCHED.md`, `MEMORY-BANK-2026-09-08.md`), reasoning from
the 16-vCPU VM's VU8 peak that TPROC-C has no scaling region on this workload **on any platform**.
I generalised a platform-independent claim from a single handicapped configuration - precisely the
same error as the baseline itself, one level of abstraction up. All three are now annotated with the
measured numbers.

## Reporting rule adopted
**Always attach the VU level to a ratio.** A bare "OSv is Nx behind" is meaningless when the ratio
triples across the sweep. Report the pair: matched-VU8 and respective-peaks, each labelled.

## Substrate proofs worth reusing (Task B)
Two checks that specifically defeat known silent-success traps:
- **postgres presence verified by SIZE**: `usr.img` 64.6 MB versus the 10.9 MB PostgreSQL-free build,
  plus 7 manifest entries. Far better than trusting the build, given the `module: build` target
  shadowed by the real `build/` directory silently produces a PG-free image that reports success.
- **OpenZFS proven BUILD-TIME**: 302 `open_zfs` objects versus **0** `bsd/.../fs/zfs` objects, plus
  all 5 OpenZFS-only userspace libs. This is the correct method now that the runtime banner I
  briefed everyone to check turns out not to exist.
- Pool properties **byte-identical to Task C**, which is what makes the cross-platform comparison
  legitimate rather than approximate.
