# BEFORE-BASELINE-RESULT — OSv-shipped vs Linux, matched QEMU ZFS-vs-ZFS

**Purpose:** durable, reproducible "before" reference. Later fix runs (tail-latency, native-fork)
diff their AFTER against this identical harness. Per `.agent/skills/osv-fair-benchmark/SKILL.md`.

Captured: 2026-08-13, us-east-2, AWS_PROFILE=fred (acct 443433794128).

---
## Provenance / reproducibility
- **Instance:** `i-061f1c45d303df48f` (osv-baseline-host, **m5d.metal**, 96 vCPU, real KVM, 4x838G local NVMe).
- **Substrate (per skill = the reliable QEMU matched harness):** BOTH guests on the SAME m5d.metal host,
  qemu **v9.1.0** built from source, **single-queue vhost tap** (`tap0`, host GW 192.168.100.1),
  driven from the host over the **tap IP (NOT loopback)**, data disk = a raw file on **local NVMe** (no EBS in data path).
  OSv guest = 192.168.100.2, Linux guest = 192.168.100.3, both `-smp 8 -m 16G -cpu host`, single-queue vhost, MAC-distinct.
- **OSv build (the shipped BEFORE-state):** `gh-fork` **W2 mmu coherence (746e5bcd + dad77b7f, dad77b7f == local `80aa4255b` by patch-id)
  + PULL wake fix (cherry-picked `579cbfed` -> `d7c3f471`)**, with **NO tail-latency batch-wake, NO RX-dispatch-fanout**.
  Boot banner: `OSv v0.57.0-450-gd7c3f471`, `WAKE_PULL ON`, `OpenZFS 5000`. `OSV_WAKE_PULL=1` (shipped default).
  Built in fedora:39 (gcc 13.3.1), musl-gcc, PostgreSQL **18.6**:
  `scripts/build fs=zfs conf_fork=1 conf_zfs=openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl`.
- **Linux:** Ubuntu 24.04.4 LTS guest, OpenZFS **2.2.2** (zfsutils-linux), PostgreSQL **18.4** (PGDG) — same PG18 major, same ZFS-on-ZFS.
- **Workload:** pgbench RO(`-S`) + RW(TPC-B default), **-s50** (5M rows, 0-failed on both), sweep c1/8/16/32/48/64,
  **3 rounds/cell + 1 discarded warmup**, `LC_ALL=C`. Median reported; per-round spread in `tps_all`.

---
## ZFS config-match PROOF (apples-to-apples storage evidence — NOT ext4)
Both pools created on local NVMe with the **IDENTICAL** property set required by the task:
`ashift=12 recordsize=8K compression=off atime=off sync=standard logbias=latency primarycache=all`.

### OSv `pgdata` (from the OSv guest, `zpool get ashift` + `zfs get`):
```
NAME    PROPERTY      VALUE       SOURCE
pgdata  ashift        12          local
pgdata  recordsize    8K          local
pgdata  compression   off         local
pgdata  atime         off         local
pgdata  sync          standard    local
pgdata  logbias       latency     local
pgdata  primarycache  all         local
```
### Linux `pgdata` (from the Ubuntu guest — BYTE-IDENTICAL to OSv):
```
NAME    PROPERTY      VALUE       SOURCE
pgdata  ashift        12          local
pgdata  recordsize    8K          local
pgdata  compression   off         local
pgdata  atime         off         local
pgdata  sync          standard    local
pgdata  logbias       latency     local
pgdata  primarycache  all         local
```
=> Storage is matched OpenZFS-vs-OpenZFS. No ZFS-vs-ext4 conflation.

---
## *** HEADLINE BEFORE-BASELINE FINDING: shipped OSv crashes at smp>=2 under PG load ***
At `-smp >= 2`, on the first pgbench backend that forks and runs, the OSv guest aborts deterministically:
```
Assertion failed: sched::preemptable() (arch/x64/mmu.cc: page_fault: 38)
[backtrace]  page_fault+254  <-  sched::timer_list::fired()  <-  invoke_interrupt  <-  interrupt
```
i.e. a **timer-IRQ-driven page fault in a non-preemptable context on the COW-fork path** — the same class
as the ROADMAP native-fork wall (nested COW fault under an IRQ), now reproduced under KVM at smp>1.
Reproduced at smp=2, 4, 8; unaffected by `-cpu host,-tsc-deadline`. **The shipped baseline therefore cannot
run a true multi-vCPU concurrency sweep on ZFS.** This instability IS what the native-fork-fix / tail-latency
work must remove. AFTER a fix, the OSv smp=8 column (below, all blank) becomes fillable — that is the headline win to measure.

Consequence for A/B: the OSv column here is at **smp=1** (the only stable OSv envelope). Linux is at smp=8.
They are NOT vCPU-matched, so the OSv/Linux ratio is a floor, not a like-for-like — the honest matched
number is blocked ON the crash, exactly as the ROADMAP predicted. The reproducible numbers are still banked.

---
## Read-Only (pgbench -S), median of 3, 0-failed

| c  | OSv-shipped smp1 tps | OSv lat(ms) | Linux-ZFS smp8 tps | Linux lat(ms) | ratio tps (OSv/Linux) |
|----|----------------------|-------------|--------------------|---------------|-----------------------|
| 1  | 6713.0  | 0.149 | 7952.3  | 0.126 | 0.84 |
| 8  | 9295.7  | 0.861 | 43580.1 | 0.184 | 0.21 |
| 16 | 9227.0  | 1.734 | 42637.3 | 0.375 | 0.22 |
| 32 | 9296.5  | 3.442 | 41618.9 | 0.769 | 0.22 |
| 48 | 8850.5  | 5.423 | 36145.0 | 1.328 | 0.24 |
| 64 | 8813.4  | 7.262 | 42553.2 | 1.504 | 0.21 |

## Read-Write (pgbench TPC-B default), median of 3, 0-failed

| c  | OSv-shipped smp1 tps | OSv lat(ms) | Linux-ZFS smp8 tps | Linux lat(ms) | ratio tps (OSv/Linux) |
|----|----------------------|-------------|--------------------|---------------|-----------------------|
| 1  | 716.7   | 1.395  | 964.4  | 1.037 | 0.74 |
| 8  | 1307.3  | 6.120  | 4087.4 | 1.957 | 0.32 |
| 16 | 1463.4  | 10.933 | 5813.0 | 2.752 | 0.25 |
| 32 | 1573.7  | 20.334 | 6606.9 | 4.843 | 0.24 |
| 48 | 1721.5  | 27.883 | 6585.7 | 7.288 | 0.26 |
| 64 | (crash) | -      | 6415.0 | 9.977 | -    |

> OSv RW c64 wedged even at smp=1 under sustained heavy RW concurrency (server closed connection); 11/12 OSv
> cells clean. The OSv smp1 tps plateau (~9.3k RO / ~1.6k RW) is single-vCPU-bound, NOT the true OSv ceiling —
> it is the stable envelope the crash forces us into. The per-query LATENCY column is the key tail-fix baseline:
> at matched vCPU (once the crash is fixed) the OSv latency at c48/c64 is the number to beat.

## Per-round spread (stability of the baseline — tight)
Linux RO: c8 [43810,43580,42558], c32 [34136,41619,46454] (widest), c64 [42553,43962,38703].
Linux RW: c32 [6627,6607,6458], c48 [6536,6586,6703], c64 [6472,6412,6415] (very tight).
OSv smp1 RO: c8 [9296,9309,9274], c64 [8813,8811,8858] (very tight).
OSv smp1 RW: c48 [1721,1723,1713] (very tight).

## Host / guest CPU at the collapse points (RO)
| c  | host idle% (96-core metal) | Linux guest idle% (8 vCPU) |
|----|-----------------------------|-----------------------------|
| 32 | 89.70 | 7.78 |
| 48 | 89.41 | 0.81 |
| 64 | 89.20 | 1.94 |
Host is ~89% idle because only one 8-vCPU guest runs on the 96-core host; the **guest itself saturates its 8 vCPUs
at c48/c64** (Linux ~1% idle) => Linux RO is guest-CPU-bound at the tail (a real constant-factor limit at 8 vCPU),
not a dispatch stall. OSv could not be sampled at smp>1 (crash).

---
## How to reproduce (for the AFTER run — use the SAME harness)
1. m5d.metal, AL2023 builder AMI, build qemu v9.1.0 from source (`--target-list=x86_64-softmmu --enable-kvm`).
2. OSv: fedora:39 container, checkout the fix branch, `scripts/build fs=zfs conf_fork=1 conf_zfs=openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl`.
   Boot via `-kernel loader-stripped.elf -append '--rootfs=zfs --ip=eth0,192.168.100.2,... --env=OSV_WAKE_PULL=1 /zpool.so import -f -N pgdata ; /zfs.so mount pgdata ; /usr/bin/postgres -D /data'`,
   usr.img as vblk0 + a 40G raw NVMe file as vblk1, single-queue vhost tap.
   Seed once: boot with `/zpool.so create -f -o ashift=12 -O compression=off -O atime=off -O recordsize=8k -O sync=standard -O logbias=latency -O primarycache=all -m /data pgdata /dev/vblk1 ; seed_copy ; postgres`,
   then host `pgbench -i -s50 -d postgres` (use the `postgres` DB — datctype C; musl PG rejects C.UTF-8).
3. Linux: Ubuntu 24.04 guest, `zpool create` with the IDENTICAL props above, PG18 (PGDG), initdb --locale=C, seed `pgbench -i -s50`.
4. Sweep: `sweep.sh <ip> <db> <label> 15..20 3` (RO -S + RW, c1/8/16/32/48/64, warmup+3 rounds, median).
5. Gate 0-failed. The AFTER win = OSv runs the smp=8 column 0-failed (crash removed) AND lower c48/c64 latency.
