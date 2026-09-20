# aarch64/Graviton3 measured results (production-shaped, OpenZFS-on-NVMe)

Identity triple: OSv **eb164dcd**, apps **b38b99cd**, ZFS **OpenZFS pool version 5000**.
Guest 32 vCPU / 64 GB, gic-version=3, `-cpu host -enable-kvm`.
`arch=aarch64 conf_fork=1 conf_zfs=openzfs fs=rofs image=zfs,zfs-tools,postgres18-musl`
PG 18.6 aarch64-unknown-linux-musl.

## Substrate PROVEN (not asserted)
ashift **12 local**, recordsize 8K, compression off, atime off, sync standard, logbias
latency, primarycache all. `fsync=on`, `synchronous_commit=on`, `autovacuum=on`,
shared_buffers 16 GB, max_connections 400, max_wal_size 16 GB, checkpoint_timeout 900.
PGDATA-on-ZFS-on-NVMe proof: `pg_relation_filepath` -> `/data/base/5/16399`, and the
sparse backing file grew **0 -> 65 MB -> 158 GB of physical blocks** as PG wrote, which is
impossible on ramfs. `/nvme` = `/dev/nvme0n1`, ROTA=0, instance store.

The three aarch64 PRs were ABSENT and cherry-picked: #1490 -> f9a3f62b, #1491 -> e3fcba8a,
#1493 -> 8711aeed. **Validated on real hardware**: a 32-vCPU/64 GB guest boots and runs,
which unpatched cannot (#1491 aborts on first IPI). `dad77b7f` deliberately excluded
(semantic conflict at core/mmu.cc:2592 with the aarch64 exception_depth>=2 block).

## pgbench (HammerDB impossible, see AARCH64-DLOPEN-FAULT.md), scale 1400 = 21 GB > 16 GB SB

| clients | r1 | r2 | r3 | median | min-max | spread |
|---|---|---|---|---|---|---|
| 8  | 1467.5 | 1357.8 | 1123.4 | **1357.8** | 1123-1468 | 25.4% FAIL |
| 16 |  982.9 | 1222.7 | 1226.6 | **1222.7** |  983-1227 | 19.9% FAIL |
| 32 | 1710.5 |  959.0 |  950.3 | **959.0**  |  950-1710 | 79.3% FAIL |
| 64 | 1097.3 |  821.2 |  188.0 | **821.2**  |  188-1097 | 110.7% FAIL |

**All four cells exceed the 15% gate, so these are NOT publishable medians.** The spread is
not noise: it is monotonic decay within each triplet (8: 1468->1123; 32: 1710->950; 64:
1097->188), because 9 GB end-of-recovery/timed checkpoints (`write=594 s`, `sync=216 s`)
land inside the later repeats. Peak median ~1358 tps at 8 clients, DEGRADING upward.
Latency 5.4 -> 13.0 -> 18.3 -> 55.4 ms avg.

The old "~2190 tps" correctness figure used a tiny in-cache dataset and is NOT comparable.

## Connect probe (the gate instrument), driver-side, timed window only

| clients | n | median | p95 | p99 | max | >=1s | >=5s | >=10s | fails |
|---|---|---|---|---|---|---|---|---|---|
| 8  | 145 | 125.1 |   733.0 |  2513.9 |  2999.4 |  7 | 0 | 0 | 0 |
| 16 | 115 | 126.7 |  2974.4 |  3652.9 |  6735.9 | 18 | 1 | 0 | 0 |
| 32 | 100 | 214.4 |  3105.5 |  8086.6 |  8880.0 | 22 | 3 | 0 | 0 |
| 64 |  65 | 244.2 | 10984.6 | **30049.3** | 30055.2 | 18 | 5 | **5** | 2 |

ms. **p99 gate FAILS, and worse than my fork-floor estimate**: 2.5 s at 8 clients rising to
**30 s** at 64. Independent corroboration of the fork floor from pgbench's own
`initial connection time`: 884 / 1792 / 3424 / 8224 ms at 8/16/32/64 = dead-linear at
**~110 ms per connect**, squarely inside the 65-150 ms/fork band. Residual fork cost.

## THE headline bottleneck finding: WAL-bound on a 98%-IDLE device

`pg_stat_activity` under load:
- VU32: `LWLock:WALWrite` on **20-31 of 32** backends, `IO:WalSync` 1, `Lock:transactionid` 4-5
- VU64: `LWLock:WALWrite` on **56 of 64**, `IO:WalSync` 1

Host `iostat -x` on the backing NVMe at the same moment: **%util 1.34 / 1.40 / 2.80**,
w_await 0.08-0.30 ms, aqu-sz 0.06-0.08. Guest qemu at 1287% CPU (~12.9 of 32 vCPU).

**So aarch64 has the SAME `LWLock:WALWrite` ceiling as x86, with the device 98% idle.** The
serialization is inside the guest's WAL-write path (`io_method=sync`, `fdatasync`), NOT
storage and NOT an ISA difference. This REFINES the earlier "I/O-bound on WAL writes"
conclusion: the earlier run inferred a device/COW bandwidth cap (~500-530 MB/s ZFS), but
here the device is idle and the cap is a guest software serialization. Both can be true on
different hardware, but on Graviton3 + local NVMe it is unambiguously software.

That is the single most actionable performance target to come out of the campaign.

## Durability PROVEN twice, unplanned
- after the VU8 crash: `redo done at 6/5D663EA0` in **67.9 s**
- after a `kill -9` mid-load: `redo done at D/29818E30` in 15.8 s + a 594 s end-of-recovery
  checkpoint, then **140,000,000 pgbench rows and the full TPROC-C dataset verified intact**
  (200 wh / 60,008,218 order_lines)
`zpool import` persists the dataset across reboots. fsync + ZIL did their job through real
crashes on aarch64. **This is the first real P5 durability evidence in the program**, and it
came from crashes rather than from a planned test.

## Canonical aarch64 boot recipe (verbatim, works) - was folklore, now recorded
    qemu-system-aarch64 -kernel build/release.aarch64/loader.img \
      -machine virt,gic-version=3 -cpu host -enable-kvm -smp 32 -m 64G \
      -nodefaults -no-user-config -no-reboot -nographic -serial mon:stdio \
      -global virtio-mmio.force-legacy=off \
      -drive file=build/release.aarch64/disk.img,if=none,id=hd0,cache=none,aio=native,format=qcow2 \
      -device virtio-blk-pci,id=blk0,drive=hd0,bootindex=0 \
      -drive file=/nvme/pgdata.raw,if=none,id=hd1,cache=none,aio=native,format=raw \
      -device virtio-blk-pci,id=blk1,drive=hd1 \
      -netdev tap,id=n0,ifname=tap0,script=no,downscript=no \
      -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
      -append "--ip=eth0,192.168.100.2,255.255.255.0 --defaultgw=192.168.100.1 ..."
Notes: `loader.img` NOT `loader.elf` (the latter dies at "premain: failed to get TLS data
from ELF"); root disk is **qcow2**, and `format=raw` yields a misleading "Cannot find the
pool label"; host qemu 11 cannot boot OSv, this ran under fedora:39 container qemu 8.1.3;
`-o ashift=12` REQUIRES `conf_zfs=openzfs`; `/zpool.so import -f pgdata` reuses the dataset.

## Deviations, all stated by the agent
pgbench not HammerDB (forced); loader.img; qcow2; `fs=rofs` root + separate OpenZFS data
disk (the OpenZFS image-builder crashes on aarch64); `conf_zfs=openzfs` added; module ramfs
default overridden; two source patches captured as diffs (`seed_copy.c` created files with
rofs read-only mode -> EPERM across PGDATA; `build.sh` needed the campaign GUCs baked in
because it re-initdbs every build); own driver at c6i.4xlarge to match the x86 arm so
driver capability is not the cross-ISA variable.
