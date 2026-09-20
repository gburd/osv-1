# a2a3lever - M1-parity: OSv vs Linux, all levers on, one variable = the OS

## Boxes (AWS lava, acct 769093516156, us-east-2, Owner=agent-a2a3lever)
    i-0eba44006fe97ac9a  m5d.metal    a2a3lever-metal  18.191.97.98  / 172.31.0.8   (BOTH arms + host)
    i-078c9e259713bb52f  c5.4xlarge   a2a3lever-drv    18.224.34.176 / 172.31.8.179 (HammerDB driver)

## Design: same box, same physical NVMe, one variable = the OS
- ONE m5d.metal, ONE physical instance-store NVMe /dev/nvme0n1 (838G) -> XFS /mnt/nv -> raw pool file.
- OSv arm: OSv KVM guest, ZFS pgdata on /dev/vblk1 (=/mnt/nv/pgdata.raw), qemu 8.1.3 fedora:39, -M pc.
- Linux arm: Alpine-edge KVM guest (musl), PG 18.6 + OpenZFS 2.4.4, SAME qemu/-M pc/virtio-blk, SAME
  raw pool file on the SAME NVMe (OSv pool destroyed first). -smp 32 -m 64G both. zfs_arc_max=32GiB.
- HYPERVISOR MATCHED: Linux in a KVM guest, NOT bare host -> removes the confound that invalidated
  the historical 213k number (BENCH-METHODOLOGY-A2A.md flagged bare-Linux-vs-KVM-OSv as invalid).
- Interference: arms run SEQUENTIALLY; OSv pool exported+destroyed, raw file recreated for Linux.

## OSv arm identity (VERIFIED on the built image)
| field | value |
|---|---|
| osv SHA | 17d814758dd6a37d00b0c21e2f0556d6763384ea (gh-fork/bench/a2a-all-levers) |
| apps SHA | 3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3 |
| ZFS submodule | 6330a45b (OpenZFS 2.4.2) |
| PG | 18.6, x86_64-pc-linux-musl, gcc 13.3.1 |
| usr.img | 118,685,696 B (114 MiB) - byte-identical to prior verified-good, NOT 8MB PG-free |
| guest | 32 vCPU / 64 GiB, -M pc -cpu host -enable-kvm, qemu 8.1.3, Booted 263.93 ms |

### Lever gates (on built source, all PASS)
    stack_guard=3  OSV_FORK_RANGE_BS=2  OSV_FORK_LARGE_SHARE=2  write_cache.empty()=1  osv::clock::wall=3
    wake_pull_enabled=true count=1
### Console at boot (WAKE_PULL armed):
    WAKE_PULL ON
    WAKE_LOCAL off
### ZFS geometry (from guest zpool/zfs get):
    ashift=12 recordsize=8K compression=off atime=off sync=standard logbias=latency primarycache=all
### GUCs (verified from driver, ALL source=command line):
    max_connections=400 shared_buffers=16GB effective_cache_size=32GB max_wal_size=64GB min_wal_size=2GB
    checkpoint_timeout=900s checkpoint_completion_target=0.9 log_checkpoints=on
    fsync=on synchronous_commit=on autovacuum=on io_method=sync
### ARC: OSv patch 0031 caps ARC at half of 64GiB guest = 32 GiB. Linux side set zfs_arc_max=34359738368.
### Reachability: driver -> 172.31.0.8:5432 (DNAT->192.168.100.2) -> PG 18.6 musl, select 1 OK.

## Progress log
- [done] boxes launched, host+driver setup
- [done] OSv image built, all gates pass
- [done] seed boot (pool created once, seed_copy, export) + run boot (PG live), WAKE_PULL ON captured
- [running] 200wh schema build against OSv
- [todo] quiesce, VU sweep 8/16/32/64 x3 OSv; then destroy pool, Linux arm same sweep

## OSv results (settled, r1 voided as cold-inflated)
### VU8: r1=158830(VOID) r2=101898 r3=104640 r4=108688 -> MEDIAN 104640, spread 6.5%
  NEWORD p99 ~49ms | connect probe p99 44ms, 0>=1s, 0 err
  wait: WALWrite ~31-34% WalSync ~10% NULL ~40-44% (WAL-fsync bound at VU8)
  host: nvme %util ~24% median, w_await 0.10-0.14ms, aqu-sz 0.58; qemu CPU ~770% of 3200 (7.7 vCPU busy)
### VU16: r1=65551 r2=64114 r3=64839 -> MEDIAN 64839, spread 2.2%
  NEWORD p99 ~64-84ms | wait: NULL ~68% WALWrite ~13-18% (idle-stall rising) | %util ~28% | qemu ~1240% (12.4 vCPU)
  -> OSv DECLINES VU8->VU16 (104640 -> 64839) even with WAKE_PULL on
### VU32: WEDGED (substrate trap, arm-independent). Guest network died (ETIMEDOUT), no OOM.
  WEDGE DIAGNOSTIC (top -H during wedge): ALL 35 qemu threads in S (sleep), 0 in R, 0 in D.
  Load 0.82, qemu ~60% of one core. => guest fully halted, NOTHING RUNNABLE.
  This CONFIRMS: the ceiling is NOT wake-placement (WAKE_PULL has nothing to steal - 0 runnable
  threads). It is a lost-wake / WAL-commit serialization wedge. WAKE_PULL is correctly a no-op.
  Consistent with VU8 7.7/32 busy + VU16 12.4/32 busy: backends BLOCKED on WAL-commit, not piled.

## Linux arm identity (VERIFIED)
| field | value |
|---|---|
| guest | Alpine Linux edge, kernel 6.12.109-0-virt, 32 vCPU / 63 GiB (=OSv -smp 32 -m 64G) |
| hypervisor | SAME qemu 8.1.3 fedora:39, -M pc -cpu host -enable-kvm, virtio-blk (MATCHED to OSv) |
| PG | 18.6, x86_64-alpine-linux-musl, cc(Alpine 15.2.0) - MUSL (matches OSv musl; triple/compiler differ) |
| ZFS | OpenZFS 2.4.4 (Alpine edge zfs-virt) vs OSv 2.4.2 - completion path identical (iowake verified) |
| NVMe | SAME physical /dev/nvme0n1 -> /mnt/nv/pgdata.raw (600G raw) -> virtio-blk vdb (OSv pool destroyed first) |
### ZFS geometry (MATCHED): ashift=12 recordsize=8K compression=off sync=standard logbias=latency primarycache=all
###   atime: property shows "on temporary" (OpenZFS 2.4.4 display quirk) but /proc/mounts shows noatime -> effectively off, matches OSv
### GUCs: all 12 source=command line, IDENTICAL values to OSv arm
### ARC: c_max=34359738368 (32 GiB) = MATCHES OSv 32 GiB cap. (bind-under-load proof pending)

## Linux results (settled, r1 voided)
### VU8: r1=158843(VOID) r2=159792 r3=161419 r4=151307 -> MEDIAN 159792, spread 6.3%
  NEWORD p99 ~34-36ms | wait (r1): NULL 51.9% WALWrite 28.5% WalSync 12.1% (WAL-fsync bound, SAME as OSv VU8)
  host: nvme %util ~30%, aqu-sz 0.56; qemu ~880% of 3200 (8.8 vCPU busy)
### VU16: r1=275290 r2=268921 r3=261387 -> MEDIAN 268921, spread 5.2%
  NEWORD p99 ~39-59ms | host: nvme %util ~47%, qemu ~1550% (15.5 vCPU busy)
  -> Linux SCALES VU8->VU16 (159792 -> 268921, +68%) where OSv DECLINED (104640 -> 64839, -38%)

## ARC BINDING PROVEN under load (Linux VU16): size 34.30-34.36 GB pinned at c_max=34359738368 (32 GiB),
   target c=c_max. max_size=100.09% of c_max. ARC saturated + binding at 32 GiB = MATCHES OSv cap.
   The comparison is NOT tilted by cache.

## SHAPE-FIX RUN (same box, a2a base + #1502 AB-BA lock-order fix)
- Branch gh-fork/bench/a2a-shape-fix, OSV_SHA d9e9dfc7, apps 3f93f43
- bench-base-gate.sh PASS on the box tree: #1504,#1505,#1472(code+default-on),#1507,#1502,FORK all present
- Question: does VU32 still WEDGE? (a2a base wedged; #1502 should clear the dentry deadlock)

### SHAPE-FIX VU32: r1=291357(VOID cold) r2=62044 r3=62832 -> WEDGE CLEARED (3 cells completed, no deadlock)
  a2a base WEDGED at VU32 (deadlock); #1502 removes it. END-TO-END PROOF for #1502.
  Settled ~62400 NOPM | NEWORD p99 ~71-77ms | qemu ~17.9 vCPU busy (vs 0 in a2a wedge) | %util ~22%
  But ~62k << Linux -> WAL-commit serialization ceiling REMAINS (the decline/flat shape persists past the deadlock).

### SHAPE-FIX VU8: r1=101047 r2=92991 (r3 wedged) -> ~same as a2a VU8 (#1502 no-op at low VU, expected)
### SHAPE-FIX VU16: guest wedged before completing (DIFFERENT wedge: postmaster ALIVE, logging
  "autovacuum worker took too long to start; canceled", all 35 qemu threads S/0-runnable).
  This is NOT the dentry deadlock (#1502 cleared that - VU32 ran 3x). Looks like a fork/worker-start
  hang - a SEPARATE OSv defect surfacing after many cells. Not pursued (budget).
