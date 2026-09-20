# dentry per-chain lock A/B — progress log

## The one variable
Branch gh-fork/bench/dentry-perchain-ab (OSV_SHA=55784926f6574dbfdd0b8bf099320ae644247525).
Same binary, boot --env toggles OSV_VFS_DENTRY_PERBUCKET:
  PERCHAIN arm: OSV_VFS_DENTRY_PERBUCKET=1 (or unset default) -> 33 per-chain locks (DENTRY_BUCKETS=32 +1 fake)
  GLOBAL   arm: OSV_VFS_DENTRY_PERBUCKET=0 -> every chain aliases chain 0 = one global mutex (old behaviour)
Mechanism fs/vfs/vfs_dentry.cc:106 dentry_perbucket_enabled(): getenv resolved once, cached, prints
  console: "VFSFLAG OSV_VFS_DENTRY_PERBUCKET" + ("=" or " unset, default ") + ("1\n"/"0\n").
  Default (unset) = 1 (per-chain). So a dropped --env would give PERCHAIN in both arms -> capture console.

## Setup verified (from box build.log, before compile finished)
- OSV_SHA=55784926f6574dbfdd0b8bf099320ae644247525 (branch tip exact)
- APPS_SHA=3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3 (seed_copy rofs fix; PHONY_COUNT=1)
- ZFS_SHA=6330a45b06d20125de679aae5f63ba14082671ef
- Base guards: stack_guard=3, OSV_FORK_RANGE_BS=2, OSV_FORK_LARGE_SHARE=2, SEEDCOPY_FIX_PRESENT=4
- cbbf74e7 confirmed ancestor of branch tip. ZIL fix (7f080f25c/1dc86f42c) present in base, left at default (not the variable).

## Boxes (Owner=agent-dentryab, lava 769093516156, us-east-2)
- METAL i-087f47d1e2483a0a5 m5d.metal   priv 172.31.12.3  pub 3.148.165.195
- DRV   i-09c0dc309f65de9f3 c5.4xlarge  priv 172.31.4.54   pub 18.221.86.151

## Plan
Build ONE image. Seed pool ONCE (200 wh / 19GB ZFS ashift=12). Then per arm boot with the flag.
VU 8,32,64. Per VU: 3 settled repeats per arm, HARDENED quiesce (2 consecutive sub-1s checkpoints).
Reboot to switch arm (flag read once/boot). Capture VFSFLAG console line every boot.
THE DELIVERABLE: pg_stat_activity wait-event histogram sampled every ~2s across the 5-min window at
VU32 and top VU, per arm. Bucket LWLock:*/Lock:*/IO:*/Client:*/NULL. NULL wait_event != on-CPU.

## Cells (appended as they complete)

## Milestones
- Image built: usr.img 118685696 (114M), loader.elf 68M, PG in manifest (6), 3 ZFS .so present,
  open_zfs objects=302, bsd zfs objects=0. Artifact gate PASS.
- Seed boot: pool created ashift=12/recordsize=8k/compression=off/atime=off/sync=standard/logbias=latency,
  seed_copy in, exported. Console VFSFLAG: "unset, default 1".
- Run boot PERCHAIN: VFSFLAG OSV_VFS_DENTRY_PERBUCKET=1 (the "=" proves --env bound). PG 18.6 ready.
- Driver->guest select 1 OK via DNAT.
- Schema built: 200 warehouses, 19 GB, all 12 GUCs source=command line.

## PERCHAIN arm (boot --env=OSV_VFS_DENTRY_PERBUCKET=1, console "=1")

### pc-vu8-r1a = 122975 NOPM [WARMUP, not counted]
Ran immediately after schema build. Quiesce log cp1=135s,cp2=0.07s,cp3=0.07s (2 consec sub-1s, PASSED
hardened quiesce) yet still 2.5x the settled repeats. Post-schema-build the DB has fresh WAL segments +
no vacuum backlog; even a hardened quiesce cannot remove that first-run advantage. Treated as warmup.
wait-hist r1a: LWLock:WALWrite=656 (dominant), Client:ClientRead=289, NULL=275, IO:WalSync=128.

### pc-vu8-r1 = 48225 NOPM (settled)  VUCOMPLETE 0s
quiesce cp1=long,cp2/3 sub-1s. wait-hist: NULL(no-wait)=685, LWLock:WALWrite=322, Client:ClientRead=237,
IO:WalSync=93. active_total=1093 active_NULL=641. (VU8 = lots of client think time -> NULL dominates.)
NEWORD p99 ~5.8ms.

### PERCHAIN VU8: r1=48225 r2=46023 r3=46686  median 46686  spread ~4.7%

### PERCHAIN VU32: r1=37193 r2=36726 r3=36031  median 36726  spread ~3.2%
KEY wait-hist (r1): NULL(no-wait)=4260 DOMINANT, LWLock:WALWrite=313, Client:ClientRead=179,
IO:WalSync=123, Lock:transactionid=8. active_total=4691 active_NULL=4197.
=> backends overwhelmingly active+NULL-wait (NOT proof of on-CPU; prior host-side showed CPU 13-15%).
LWLock contention is TINY (313 total). This is the same idle-device/idle-CPU stall shape.

### PERCHAIN VU64 r1 = 33167 NOPM
host instr: iostat %util median 13.5% (9.6-16.7), w_await 0.14ms, aqu-sz 0.24, wkB/s ~76MB/s;
qemu CPU ~372-401% of one core / 3200 = ~12% of 32 vCPU. DEVICE IDLE AND CPU IDLE (same stall).
KEY wait-hist (top VU): NULL(no-wait)=8575 DOMINANT (~90% of active), LWLock:WALWrite=667,
IO:WalSync=105, Lock:transactionid=76, Client:ClientRead=178. active_total=9490 active_NULL=8523.
=> With CPU 88% idle, the NULL-wait dominance is provably NOT on-CPU. Serialization is OSv-side, invisible to PG.

### PERCHAIN VU64 r2 = STALL [datapoint, not counted]
r2 hit a driver-side HammerDB tcl CLI error (VUCOMPLETE_AFTER 1500s, no NOPM). Then the r3 quiesce
CHECKPOINT never converged: console shows "03:05:15 checkpoint starting: time" that never completed
(>25 min), and "autovacuum worker took too long to start; canceled" every ~75s continuously. select 1
also stalled (new-backend/worker machinery cannot get scheduled). SAME checkpointer/worker wakeup stall
zilab documented at VU64. This is itself the datapoint: a background worker cannot be woken while the
device is 86% idle and CPU 88% idle -> scheduling/wakeup problem, not IO bandwidth. Captured console to
raw/console-pc-stall.log. Did NOT fight it (per brief). Killed sweep, rebooting to GLOBAL arm.

### PERCHAIN ARM COMPLETE (usable): VU8=46686 VU32=36726 VU64=33167(1pt)
Boot proof: VFSFLAG OSV_VFS_DENTRY_PERBUCKET=1 (the "=" = --env bound).

## GLOBAL arm boot: VFSFLAG OSV_VFS_DENTRY_PERBUCKET=0 (DIFFERENT from PERCHAIN =1 -> A/B valid)
Exactly ONE qemu-system-x86 (PID 26264) confirmed before proceeding (no 2-QEMU slip).
End-of-recovery checkpoint from the killed PERCHAIN guest: started 03:34:17, COMPLETED 03:42:57
= 519.9s (8.7 min) to write 1,016,833 buffers. write=519.858s sync=0.032s.
  => The stall lives in the WRITE phase (~2000 buffers/s = ~15 MB/s) NOT sync, NOT device (86% idle).
  Each buffer-write syscall is completed slowly by OSv. This IS the NULL-wait stall, seen bare.
frozen state_change snapshot taken just AFTER recovery (03:43:12/17): all bg workers idle in
  Activity:*Main (checkpointer 3036=CheckpointerMain, bgwriter, walwriter, autovac launcher);
  only client backend = my transient select-1 probe. Confirms: when NOT under checkpoint load, PG
  bg workers park normally. The stall is the slow per-buffer write path under load, not a dead latch.
  raw/frozen-sample{1,2}-recovery.txt
OSv HTTP API: NOT present in image. QEMU gdbstub: NOT enabled (no -s). gdb installed in container but
  cannot reach guest threads without gdbstub. Option-3 (frozen state_change) is the reachable instrument.

## GLOBAL arm (boot --env=OSV_VFS_DENTRY_PERBUCKET=0, console "=0")
### gl-vu8-r1 = 114439 NOPM [WARMUP, not counted] -- first cell after 8.7min recovery, same inflation as pc-r1a.

### GLOBAL VU8: r2=45893 r3=48959 (r1=114439 warmup discarded) settled median ~47426
COMPARE VU8: PERCHAIN median 46686 vs GLOBAL median (r2,r3) 47426 -> delta -1.6% -> NULL (within spread).

## OSv-side stall instrument (option 3, frozen state_change) @ GLOBAL VU32 under load
3 sample-sets (04:27:27/40/54), each two pg_stat_activity snaps 5s apart:
  active client backends STALLED (state_change frozen while active): 0 of 32  (all 3 sets)
  active client backends PROGRESSING: 31-32 of 32
  bg workers: checkpointer/walwriter/autovac/logical all idle in Activity:*Main;
              background writer cycling IO:DataFileWrite / IO:DataFileFlush (real IO).
INTERPRETATION: The wait_event=NULL dominance is NOT backends frozen on a dead wakeup. Backends are
  RAPIDLY CYCLING through brief active/runnable states (each <5s, so state_change advances every sample),
  each too short to register on a PG wait event. Combined with host CPU ~12% and NVMe ~13%: a
  per-transaction OSv-side latency tax (syscall completion + scheduler round-trips) spread across every
  transaction, not a single serialization wedge. HTTP-API/gdb-thread dump unreachable (no httpserver in
  image, no QEMU gdbstub); this frozen-state instrument is the reachable kernel-side proxy. raw/frozen2-gl-vu32-*.json

### GLOBAL VU32 r1 = 37318 NOPM (vs PERCHAIN 37193 -> +0.3% NULL)
KEY discriminator - VU32 wait histograms are NEARLY IDENTICAL between arms:
  bucket        PERCHAIN  GLOBAL
  NULL(no-wait)  4260      4275
  LWLock:*        313       278   <- did NOT drop with per-chain locks
  Client:*        179       188
  IO:*            144       136
  Lock:*            8        18
  active_NULL    4197      4221
=> Splitting the dentry lock changed NOTHING in the wait profile. Backends are not contending on it.

### GLOBAL VU32: r1=37318 r2=36653 r3=36258  median 36653  spread ~2.9%
COMPARE VU32: PERCHAIN 36726 vs GLOBAL 36653 -> delta +0.2% -> DEAD NULL.

### GLOBAL VU64 r1 = 32974 NOPM (vs PERCHAIN 33167 -> -0.6% NULL)
host instr: iostat %util median 16.7% (12.2-20.4), w_await 0.20ms, aqu-sz 0.33, wkB/s ~84MB/s;
qemu CPU ~398-426% of one core / 3200 = ~13% of 32 vCPU. DEVICE IDLE AND CPU IDLE (same as PERCHAIN).
KEY top-VU discriminator - VU64 wait histograms NEARLY IDENTICAL:
  bucket        PERCHAIN  GLOBAL
  NULL(no-wait)  8575      8374
  LWLock:*        670       765   <- did NOT drop with per-chain locks
  IO:*            192       289
  Client:*        178       183
  Lock:*           77        77   <- identical
  active_NULL    8523      8331
frozen2 @ VU64 GLOBAL under load: 0 of 62-64 active backends stalled; all progressing. No dead wedge.

## VERDICT SO FAR: NULL at every VU. Splitting dentry lock changes neither throughput nor wait profile.
  VU8:  PC 46686 vs GL ~47426  (-1.6%)
  VU32: PC 36726 vs GL 36653   (+0.2%)
  VU64: PC 33167 vs GL 32974   (+0.6%)

### GLOBAL VU64 r2 = 0 NOPM / 7 TPM [DUD, not counted]
Same VU64 stall zilab hit (their VU64-OFF r2 = 0 NOPM/125 TPM). 64-VU connection storm produced ~no
work; "Test complete" with 0 NOPM. select 1 then hung, checkpoint starting:time at 05:39 not completing.
Stopped sweep here (do not fight VU64 per brief). Have solid VU64 r1 in BOTH arms + both histograms.

## DONE. Result: NULL at every VU; wait histograms identical between arms. Dentry lock RULED OUT.
Console: PERCHAIN =1, GLOBAL =0 (different -> A/B valid). Terminating boxes next.

## TERMINATED + orphan audit clean
i-087f47d1e2483a0a5 terminated | i-09c0dc309f65de9f3 terminated
0 live instances Owner=agent-dentryab, 0 tagged volumes, 0 available orphan volumes.
Raw packaged: dentryab-raw.tgz. Result: RESULT-dentryab.md (NULL at every VU; histograms identical).
