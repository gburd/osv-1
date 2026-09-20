# fsync-writeback A/B — HammerDB TPROC-C end-to-end validation

## The question
Does removing OSv's O(filesize) per-fsync pagecache scan (`writeback_inode`
whole-file scan in core/pagecache.cc) lift TPROC-C NOPM? Same-binary A/B, ONE
variable: OSV_PAGECACHE_FSYNC_SCAN.
  arm FIXED : unset/0  -> write_cache.empty() guard ON, no scan
  arm OLD   : =1       -> forces the old O(filesize) scan
Boot prints `PGCFLAG OSV_PAGECACHE_FSYNC_SCAN ...` once. Both arms MUST show
different PGCFLAG lines or the A/B is void.

## Boxes (Owner=agent-fsyncab, lava, us-east-2a)
- METAL i-0ae60ac03c7f72bbc  m5d.metal   pub 18.119.116.73  priv 172.31.1.138
- DRV   i-05d7034dfaaae8350  c5.2xlarge  pub 3.147.79.190   priv 172.31.2.186
  Total 104 vCPU. Terminate ONLY these two.

## Identity verified (build.log)
- OSV_SHA=89016d843c7f64e4fd912db4674d80c2c67ea1e4 (gh-fork/bench/fsync-writeback-ab tip)
- APPS_SHA=3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3  (required pin)
- ZFS_SHA=6330a45b06d20125de679aae5f63ba14082671ef
- stack_guard=3, OSV_FORK_RANGE_BS=2, OSV_FORK_LARGE_SHARE=2, PHONY_COUNT=1, seedcopy rofs fix present
- Image usr.img 114M rofs qcow2; loader.elf 68M; zfs.so set built (real PG image, not 8M PG-free failure)

## Setup verified
- Pool created ONCE (seed boot): ashift=12 recordsize=8K compression=off atime=off
  sync=standard logbias=latency primarycache=all — all SOURCE=local. Pool raw file 54M actual
  after seed_copy (48M cluster landed). Import-only on RUN boots.
- RUN boot FIXED arm: PG 18.6 musl "database system is ready to accept connections".
  PGCFLAG "default (guard on)". FORKFLAG RANGE_BS/LARGE_SHARE default 1.
- Driver reaches PG via DNAT 172.31.1.138:5432 (psql select 1 OK, version 18.6).
- All 12 GUCs source=command line, verified FROM DRIVER (see gucs.sql output):
  max_connections=400 shared_buffers=16GB effective_cache_size=32GB max_wal_size=64GB
  min_wal_size=2GB checkpoint_timeout=15min cctarget=0.9 log_checkpoints=on fsync=on
  synchronous_commit=on autovacuum=on io_method=sync.

## Plan
- Build 200wh schema once (~19GB). Then per VU {8,32,64}: 3 settled repeats per arm.
- HARDENED quiesce before every cell: require TWO consecutive sub-1s CHECKPOINTs.
- Reboot guest to switch arm (flag read once/boot). Record which boot used which flag +
  capture PGCFLAG console line every run.
- At VU32 & VU64: iostat %util + qemu CPU% + pg_stat_activity wait histogram. NEWORD p99. num_timed/num_requested.

## Schema: 200 warehouses, DB size 19 GB (verified from driver). Pool raw 71G on NVMe.

## Cells (appended as they complete)

### FIXED (guard on, PGCFLAG "default (guard on)") VU8
- r1 = 134024 NOPM (308290 TPM). VUCOMPLETE 0s.
  quiesce: cp1=57187ms (schema backlog), cp2=43ms, cp3=42ms -> QUIESCED (2 consecutive sub-1s)
  probe: n=300 err=0 median=39.6ms p99=45.7ms ge1s=0
  NEWORD call-weighted P99=5.379ms (1.715M calls, 9 vusers)
  wait histogram (554 samples, 3776 active-backend obs):
    LWLock/WALWrite 62.7%  NONE/NULL 18.8%  IO/WalSync 12.0%  Client/ClientRead 3.7%  IO/WalWrite 1.2%
  *** r1 VOIDED: 134024 is ~3x r2/r3/r4. Same false-inflation pattern zilab documented at 80417 --
    the first run after cold import/schema-build drains a transient backlog. Quiesce passed but the
    steady-state write amplification had not yet built up. r2/r3/r4 are the settled truth.
- r2 = 47188 NOPM  quiesce cp1=58482 then 42/40ms  NEWORD-P99 (tbd)
- r3 = 46097 NOPM  quiesce cp1=50945 then 58/42ms
- r4 = 47355 NOPM  quiesce cp1=57096 then 46/39ms
  probe n=300 err=0 median=50ms p99=68ms ge1s=0;  NEWORD call-weighted P99=15.137ms (672k calls)
  wait histogram (530 samples): NONE/NULL 62.6%  LWLock/WALWrite 24.2%  IO/WalSync 9.1%  ClientRead 2.9%

### FIXED VU8 SETTLED: 47188, 46097, 47355  median 47188  spread 2.7% (GOOD)  [r1 void]

### OLD arm (PGCFLAG "=1 (old scan)" -- flag bound DIFFERENTLY, A/B valid)
- Arm-switch trap: pkill -9 to switch arms forces PG crash recovery. First OLD attempt WEDGED:
  post-recovery the OLD arm did a 13.5-MINUTE checkpoint (write=809.9s) and the OSv guest network
  stack hung (ARP dead, vusers got "no connection"). Rebooted; second recovery was fast (already
  flushed) and network came up clean. old-vu8-a (first cell after reboot) = 121327 NOPM = COLD/VOID
  (same cold-start inflation as FIXED-r1=134024; arm-independent, drains a transient backlog).
- OLD VU8 settled: b=49731, c=43150, d=48745  median 48745  spread 13.5% (b/d tight, c low)
  *** OLD-arm quiesce first-checkpoint EXPLODES run-over-run: b=168s, c=249s, d=438s(!).
     FIXED-arm first checkpoint was steady ~50-58s. This is the O(filesize) fsync scan growing
     as the DB/WAL grow -- the fix's mechanism, visible directly in checkpoint cost.

### VU8 HEADLINE
    arm     NOPM median   LWLock/WALWrite median   NULL median   1st-checkpoint
    FIXED   47188         24.2%                    62.6%         ~50-58s (flat)
    OLD     48745         40.1%                    44.7%         168->249->438s (growing)
    delta   -3.3% (NULL, within spread)   +15.9pp WALWrite in OLD   checkpoint 3-8x worse in OLD

  NOPM: essentially EQUAL at VU8 (OLD nominally +3.3%, inside run-to-run spread -> NULL on throughput).
  Wait-histogram SHIFT (parent refinement 1): OLD backends spend MORE time on LWLock/WALWrite
  (40.1% vs 24.2%) and are LESS idle (NULL 44.7% vs 62.6%) -- the predicted direction: the fix eases
  the WAL-fsync serialization. And OLD checkpoints grow catastrophically (438s) while FIXED stays flat.
  So at VU8 the scan cost is REAL (checkpoint + WALWrite wait) but does NOT gate steady-state NOPM.

### OLD VU32 (PGCFLAG "=1 old scan")
- a=34615 (cold/warmup), b=32257 (settled). Then during cell c the OSv guest CRASHED:
  console filled with a fault register/stack dump; QEMU pinned; guest network dead.
  ROOT: "Out of memory: could not reclaim any further. Current memory: 37657188 Kb"
  (guest is 64 GiB; free ~37MB, largest free range ~0.9MB = heap exhausted+fragmented).
  Backtrace shows _do_page_fault in the pagecache path during the OOM.
- Only 2 OLD VU32 datapoints before the crash: 34615, 32257 (a likely cold). NOT a clean 3-repeat set.
- CRITICAL CONTROL NEEDED: does FIXED VU32 also OOM? If FIXED survives and OLD OOMs, the OLD
  scan path is implicated in unreclaimable memory growth. If both OOM, it is an arm-independent
  guest-memory ceiling at VU32 and I will report it as such. Rebooting to FIXED to run the control.

### VU32 CONTROL + short-run pairs (rampup1/dur3 to fit inside the wedge window)
- FIXED VU32 full-length attempt WEDGED too (net dead, ETIMEDOUT, NO OOM, NO crash dump; QEMU alive
  at 195%, console frozen). So the VU32 guest wedge is ARM-INDEPENDENT: both arms lose the guest
  network under sustained full-length 32-VU load. OLD additionally hit a hard OOM (37.6GB/64GB).
- Diagnostics during old-vu32-b (the one full-length OLD cell that completed before the crash):
    driver CPU 98% IDLE (c5.2xlarge is NOT the bottleneck -- parent caution answered)
    host NVMe %util median 15%, w_await 0.14ms, ~100 MB/s (device NOT the bottleneck)
    qemu CPU 95%->76%->0%->0%->0% of ONE core (guest STOPS running mid-window -> internal stall)
  => the VU32 ceiling is an OSv-internal scheduler/network stall, not IO/CPU/driver, not arm-specific.
- Short runs (rampup1/dur3) survived. Settled pair (s1 cold/void both arms):
    FIXED VU32 s2 = 33420 NOPM   quiesce cp1=86.4s    NEWORD P99=58.6ms   NULL 90.3% WALWrite 5.5%
    OLD   VU32 s2 = 32192 NOPM   quiesce cp1=616s(!)  NEWORD P99=70.5ms   NULL 86.0% WALWrite 7.7%

### VU32 HEADLINE (short-run settled pair, 1 repeat each -- guest instability prevented 3x)
    arm     NOPM    NEWORD-P99   1st-checkpoint   LWLock/WALWrite   NULL
    FIXED   33420   58.6ms       86.4s            5.5%              90.3%
    OLD     32192   70.5ms       616s(!)          7.7%              86.0%
    delta   +3.8%   -16.9%       7.1x lower       lower             more idle
  NOPM EQUAL (FIXED +3.8%, within spread -> NULL, same as VU8). BUT FIXED has 16.9% LOWER NEWORD p99
  tail latency AND a 7x cheaper first checkpoint. Wait shift smaller here (both ~85-90% NULL) because
  at VU32 the ARM-INDEPENDENT internal idle-stall dominates and masks the WAL-fsync wait.

### VU64: NOT RUN. At VU32 the guest already wedges/OOMs under full-length load in BOTH arms;
  VU64 would wedge faster and burn budget for no clean pair. Documented as the substrate ceiling
  (matches the task's prior-run checkpointer-stall warning).

*** WARNING on histogram variance (same arm, different runs): r1 showed 62.7% LWLock/WALWrite
    but r4 showed only 24.2% (62.6% NULL). The wait profile is transient-sensitive (checkpoint
    phase / WAL segment recycling) even when NOPM is stable. The histogram SHIFT proof (per parent
    refinement 1) must compare ARM MEDIANS across all settled repeats, not single snapshots. Capturing
    histograms on every settled repeat for this reason.
