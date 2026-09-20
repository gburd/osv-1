# Second benchmark campaign: gated on two kernel fixes, deliberately

2026-09-08. User asked to re-run the full OSv-vs-Linux benchmark matrix (bare metal +
Firecracker, x86_64 + aarch64, external load, ZFS, no tmpfs, fsync/autovacuum ON,
statistically valid). **I am not launching the benchmark arms yet, and this records why.**

## Why re-running now would reproduce nothing but the same crashes

Both OSv arms in the 2026-09-07 campaign produced **zero NOPM**. Not slow numbers - no
numbers, because the guest kernel faulted before the timed window opened. Verified still
unfixed on every branch:

    x86_64:  ARC/pagecache reclaim unmaps a loaded ELF page under dlsym.
             5 occurrences, byte-identical address, QEMU-KVM **and** Firecracker.
             9-minute reproducer exists. `grep mlocked core/pagecache.cc` -> nothing.
    aarch64: vm_fault cannot populate a mapped file-backed ELF page.
             Deterministic at 1 connection; every plpgsql call faults.
             All 6 HammerDB TPROC-C procs are plpgsql, so NOPM is unobtainable at any VU.

Spending 3-4 bare-metal boxes to re-derive "it crashes at VU8" would be paying to confirm
what we already know at byte-level precision. The gate is the bug, not the measurement.

## Dispatched instead: the two blockers, in parallel

| agent | target | box |
|---|---|---|
| 0261152a | x86 ELF-page-reclaim fix + PR | m5d.metal, tagged Owner=agent-elfreclaim |
| 541f3862 | aarch64 vm_fault populate failure | c7gd.metal, tagged Owner=agent-aarch64elf |

Both briefed with: the full substrate footgun list, the honesty gate (**no "fixed" without a
pasted PRE-fix fault and a pasted POST-fix clean run of stated duration on the same setup**),
and explicit permission to refute my mechanism. The x86 one carries the fix design I said I
would own; the aarch64 one is genuinely open and is told to instrument before theorising.

**Boxes now tagged with `Owner=agent-<id>`** so a second agent can tell whose box it is
without inferring from file mtimes. That is a direct fix for today's two-agents-one-box
collisions.

## What the benchmark campaign will get, once unblocked

Everything is already prepared, which is why gating costs little:
- **Config mandate settled and proven achievable**: ZFS ashift=12/recordsize=8k/compression=off/
  atime=off/sync=standard/logbias=latency/primarycache=all; fsync on, synchronous_commit on,
  autovacuum on, no tmpfs; PGDATA+WAL on ZFS-on-NVMe with `SHOW data_directory` + `df` +
  `zpool status` proof.
- **Version parity is a gate, not a caveat**: PG **18.6** from `REL_18_STABLE` with the
  identical configure line on every arm, and **`io_method=sync` matched** (OSv's AIO path is
  incomplete, so Linux's default `worker` would be a confound).
- **Linux reference already measured** (`bench-linux/LINUX-BASELINE-RESULTS.md`): peak
  **99,504 NOPM @ VU8**, declining after; connect probe 4350 samples with **zero >= 1 s**;
  `LWLock:WALWrite` on 55/64 backends but with the device **73-93% utilised**, which is the
  discriminator against OSv's idle-device version of the same signature.
- **Known config defect to fix in the re-run**: `checkpoint_timeout=15min` never fires
  (`num_timed=0`; 49/51 checkpoints WAL-triggered every ~72 s), which is the structural cause
  of the 30-35% spreads. Raise `max_wal_size` or lengthen `pg_duration`.
- **Known substrate correction**: `m5d.4xlarge` has **TWO** instance-store NVMe devices; the
  single-device `zpool create` left one idle and capped the storage-bound cells.
- **Correct future matching**: Linux on **m5d.metal with cores restricted**, not OSv on a VM
  slice, because OSv needs /dev/kvm and only metal types provide it.
- **The instrument that matters**: an independent fresh-connect probe (1/s, alone during timed
  windows, NOPM reported alongside). It exposed a 19 s stall HammerDB's own percentiles hid
  completely, and it is what discriminated the ZFS-checkpoint hypothesis from the OSv
  connect-path bug.

## Trigger to launch the arms
Either blocker fixed and validated -> launch that ISA's arms immediately (bare metal +
Firecracker, external driver, 3 repeats, spread flagged >15%). Both fixed -> full matrix in
parallel; quota is 512 vCPU so capacity is not the constraint.
