# a2abench7 - LIVE LOG (written as each step lands)

## Boxes (AWS_PROFILE=lava, acct 769093516156, us-east-2, Owner=agent-a2abench7)
    i-0ce983c4cb91921cf  m5d.metal    a2abench7-x86-m5d   3.129.70.203   / 172.31.1.7
    i-031434d1538558de9  c7gd.metal   a2abench7-arm-c7gd  18.217.207.217 / 172.31.5.123
    i-06b5f679718f7e389  c5.4xlarge   a2abench7-drv-x86   3.148.179.148  / 172.31.4.2
    i-02162e8211e14b30f  c5.4xlarge   a2abench7-drv-arm   3.144.115.73   / 172.31.13.240

Capacity at launch: 352 of 640 vCPU in use, 288 free (operator's number was right;
the 10 solnix m5.4xlarge exited between my first check and theirs).

## ARM 1 (x86_64 QEMU-KVM on m5d.metal) - identity tuple
| field | value |
|---|---|
| osv SHA | `cbbf74e7184033861c25ad47cd37376ede6f0c79` (`gh-fork/fix/tcb-psabi-guards`) |
| apps SHA | `3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3` (seed_copy rofs-mode fix) |
| ZFS submodule SHA | `6330a45b06d20125de679aae5f63ba14082671ef`, META Version 2.4.2 |
| PG branch / version | `REL_18_STABLE` / **PostgreSQL 18.6**, `x86_64-pc-linux-musl`, gcc 13.3.1 |
| configure/build line | `conf_fork=1 conf_zfs=openzfs fs=rofs --use-openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl` |
| hypervisor | qemu 8.1.3 in fedora:39, `-M pc -cpu host -enable-kvm`, `-kernel loader.elf` |
| guest | 32 vCPU / 64 GiB, `Booted up in 257.37 ms`, OSv v0.57.0-519-gcbbf74e7 |

### Build gates (artifacts, NOT scripts/build exit code)
    stack_guard=3  OSV_FORK_RANGE_BS=2  OSV_FORK_LARGE_SHARE=2
    APPS_SHA=3f93f43...  PHONY_COUNT=1  (re-checked after submodule update)
    usr.img      = 118,685,696 B (114 MiB)   <- NOT the ~8 MB PG-free signature
    loader.elf   = 71,202,968 B
    postgres bin = 50,028,736 B
    open_zfs objects: 302   bsd zfs objects: 0   bsd zfs spa objects: 0
    libzfs_core/libzutil/libshare/libtpool in usr.manifest: 1/1/1/1
    /data-seed in image: 1292 files, 28 dirs
Byte-identical usr.img and postgres sizes to the previous verified-good run.

### Runtime fork flags (from guest console)
    FORKFLAG OSV_FORK_TIMING unset, default 0
    FORKFLAG OSV_FORK_RANGE_BS unset, default 1
    FORKFLAG OSV_FORK_LARGE_SHARE unset, default 1

### ZFS substrate (from the guest, `zpool get` for ashift)
    pgdata  ashift        12        local
    pgdata  recordsize    8K        local
    pgdata  compression   off       local
    pgdata  atime         off       local
    pgdata  sync          standard  local
    pgdata  logbias       latency   local
    pgdata  primarycache  all       local
Chain: /data (ZFS pgdata) -> /dev/vblk1 -> /mnt/nv/pgdata.raw (600 GiB raw)
    -> XFS on /dev/nvme0n1 (Amazon EC2 NVMe Instance Storage, 838 GiB). NO tmpfs.
Pool created ONCE in a seed boot, then import-only per benchmark boot.

### GUCs verified EXTERNALLY from the driver: all `source=command line`
    autovacuum on | checkpoint_completion_target 0.9 | checkpoint_timeout 900s
    effective_cache_size 4194304 8kB (32GB) | fsync on | io_method sync
    log_checkpoints on | max_connections 400 | max_wal_size 65536MB (64GB)
    min_wal_size 2048MB | shared_buffers 2097152 8kB (16GB) | synchronous_commit on
    data_directory /data/pg (override)

### Driver reachability, proven before load
    1|192.168.100.2|172.31.4.2|PostgreSQL 18.6 on x86_64-pc-linux-musl...

## Deviations / findings so far
1. Ubuntu AMI ami-00adec9774170bad2 is x86_64-only -> both drivers are c5.4xlarge.
   Deliberate: the driver is a pure TCP client, so identical drivers remove a
   variable rather than adding one.
2. `seedprep.sh` is DEAD CODE on the rofs path and its `INITDB_RC=0` is a false
   green (it is the tail pipeline's rc). The musl interpreter /lib/ld-musl-x86_64.so.1
   does not exist on the AL2023 host, so host-side initdb cannot run at all.
   Not needed: the apps build already bakes a real 46 MB / 1292-file cluster at
   /data-seed with a permissive pg_hba. Skipped it.
3. `zfs get used` reporting 396K right after seed_copy + before export is
   pre-txg-sync accounting, NOT a failed copy - proven by the run boot finding
   "database system was shut down at 2026-09-11 14:05:18 UTC" and starting clean.

## CONTAMINATION FOUND AND CORRECTED (important, affects methodology)
VU8 r1=80417, r2=44951 -> 79% spread, way over the 15% flag. Cause is NOT variance:
the guest console shows a checkpoint that ran 14:26:51 -> 14:40:21 = **809.4 s**,
writing **1,793,759 buffers (85.5% of the 16 GB shared_buffers)**, distance 23.4 GB.
That is the post-schema-build dirty backlog draining, and r1/r2 both ran inside it.
r1 (earlier, less backlog pressure) got 80417; r2 (deeper into the flush) got 44951.

Corrective action: drove two explicit CHECKPOINTs from the driver. The first took
**3m32.8s** (the real backlog), the second **0.034 s** (write=0.031s, 0 buffers) =
system quiescent. All reported VU8 cells are re-run from this settled state and
tagged s1/s2/s3. r1/r2 are retained in cells/ as contaminated, not used in medians.
This is a real methodology trap: HammerDB's schema build leaves ~23 GB of dirty
buffers, and a 7-minute cell started right after it measures the checkpoint, not PG.
