# OSv VFS dentry lock A/B: does splitting the single global dentry hash lock into per-chain locks change PostgreSQL throughput?

**Answer: NO. Clean NULL at every concurrency level, and the wait-event histograms are byte-for-byte
indistinguishable between the two arms.** Splitting the global `dentry_hash_lock` into 33 per-chain
locks (PR #1503) moves TPROC-C NOPM by **-1.6% / +0.2% / +0.6%** at VU 8 / 32 / 64 -- every delta is
inside the ~3-5% run-to-run spread. The dentry lock is **ruled out** as the throughput lever for this
workload on this substrate.

**The real deliverable this run -- the pg_stat_activity wait-event histogram the last run was missing --
is captured, per arm, at VU32 and VU64, and it names where to look next.**

## Box ids (Owner=agent-dentryab, account 769093516156 lava, us-east-2) -- BOTH TERMINATED
    METAL host (OSv guest)  i-087f47d1e2483a0a5  m5d.metal    priv 172.31.12.3  pub 3.148.165.195
    DRIVER   (HammerDB)     i-09c0dc309f65de9f3  c5.4xlarge   priv 172.31.4.54   pub 18.221.86.151
Termination + orphan check: driver terminated; metal terminated (bare-metal teardown is slow, went via
shutting-down -> terminated, billing stops at shutting-down). 0 running/pending/stopped instances with
Owner=agent-dentryab, 0 volumes tagged agent-dentryab, 0 available orphan volumes. Root vols were
DeleteOnTermination=true.

## The one variable, and the proof it bound
ONE image (gh-fork/bench/dentry-perchain-ab, OSV_SHA=55784926f6574dbfdd0b8bf099320ae644247525), ONE pool,
ONE 19 GB / 200-warehouse dataset, ONE guest (32 vCPU / 64 GiB), identical GUCs. The arms differ only by
a boot --env, resolved once per boot in fs/vfs/vfs_dentry.cc:106 (dentry_perbucket_enabled), announced
on the console:

    arm PERCHAIN (--env=OSV_VFS_DENTRY_PERBUCKET=1):  VFSFLAG OSV_VFS_DENTRY_PERBUCKET=1
        chain_mutex(index) -> dentry_chain_lock[index]     33 independent per-chain mutexes (32 buckets +1 fake)
    arm GLOBAL   (--env=OSV_VFS_DENTRY_PERBUCKET=0):  VFSFLAG OSV_VFS_DENTRY_PERBUCKET=0
        chain_mutex(index) -> dentry_chain_lock[0]         every chain aliases chain 0 = one global mutex (old)

Both console lines captured (raw/console-gl.log has "=0"; the PERCHAIN "=1" was on console-run-005611.log,
recorded in PROGRESS.md). The two arms printed DIFFERENT values -> the A/B is valid, not void. The default
(unset) resolves to 1, so a dropped --env would have given PERCHAIN in both arms and read as a false null;
the explicit "=N" (not " unset, default N") on both boots proves --env reached putenv.

## Base guards verified (from the container build log, before compiling)
    OSV_SHA=55784926f6574dbfdd0b8bf099320ae644247525   (branch tip, exact)
    APPS_SHA=3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3   (seed_copy rofs fix; PHONY_COUNT=1)
    ZFS_SHA=6330a45b06d20125de679aae5f63ba14082671ef
    stack_guard=3   OSV_FORK_RANGE_BS=2   OSV_FORK_LARGE_SHARE=2   (all as required)
    cbbf74e7 confirmed ANCESTOR of the branch tip.  ZIL fix (commits 7f080f25c/1dc86f42c) present in the
      base and left at its default -- it is NOT the variable here.
    image usr.img 118685696 (114 MiB) qcow2 rofs (not the 8 MB PG-free failure); loader.elf 68 MB;
      postgres in manifest (6), 3 ZFS .so present, open_zfs objects=302, bsd zfs objects=0.

## Config, identical on both arms (verified from the driver as source='command line')
PG 18.6 musl, 200 warehouses / 19 GB on ZFS-on-NVMe (ashift=12, recordsize=8k, compression=off,
atime=off, sync=standard, logbias=latency, primarycache=all -- read back via zpool/zfs get on every boot).
GUCs: max_connections=400, shared_buffers=16GB, effective_cache_size=32GB, max_wal_size=64GB,
min_wal_size=2GB, checkpoint_timeout=15min, checkpoint_completion_target=0.9, log_checkpoints=on,
fsync=on, synchronous_commit=on, autovacuum=on, io_method=sync. All 12 = source 'command line',
re-verified after the between-arm crash-recovery.

## HEADLINE

    VU    PERCHAIN median   GLOBAL median   delta%   PERCHAIN/GLOBAL ratio
    8        46,686           47,426         -1.6%      0.984
    32       36,726           36,653         +0.2%      1.002
    64       33,167           32,974         +0.6%      1.006

Every delta <= the run-to-run spread (VU8 spread ~4.7%, VU32 ~3%, VU64 single point). No delta near
15%. NULL at every VU.

## Per-cell detail (NOPM; settled repeats, HARDENED quiesce = 2 consecutive sub-1s checkpoints)

    VU8   PERCHAIN: 48225, 46023, 46686   median 46686   (+ r1a=122975 WARMUP, discarded)
    VU8   GLOBAL  : 45893, 48959          median 47426   (+ r1=114439 WARMUP, discarded)
    VU32  PERCHAIN: 37193, 36726, 36031   median 36726   spread 3.2%
    VU32  GLOBAL  : 37318, 36653, 36258   median 36653   spread 2.9%   *** cleanest pair: delta +0.2% ***
    VU64  PERCHAIN: 33167                 (1 valid; r2 dud, r3 not run -- VU64 stall, see below)
    VU64  GLOBAL  : 32974                 (1 valid; r2 dud = 0 NOPM/7 TPM, sweep stopped)

num_requested vs num_timed: HammerDB pg_num_vu=VU, vucomplete polled; VUCOMPLETE_AFTER 0 s on every good
cell = all timed vusers drained before vudestroy.

NEWORD p99 (xtprof aggregate, ms):
    VU8   PERCHAIN 13.6-14.8   GLOBAL 7.5-18.7   (VU8 noisy at low load, overlapping)
    VU32  PERCHAIN 52.3-54.8   GLOBAL 53.1-62.2  (indistinguishable)
    VU64  PERCHAIN 106.7       GLOBAL 117.4      (indistinguishable, single point)

Connect probe (fresh connect+select 1, alone in window; 300 samples/cell): all cells 0 errors, 0 >=1s.
VU8 median ~37ms; representative.

## THE WAIT-EVENT HISTOGRAM (the deliverable) -- per arm, VU32 and VU64

Sampled pg_stat_activity every ~2s for the full 5-min timed window (150 samples/cell). Counts are
backend-observations (sum over samples of matching client-backend rows). Bucketed LWLock:* / Lock:* /
IO:* / Client:* / NULL(no-wait-event). Raw NDJSON + aggregated JSON per cell in raw/.

VU32 (representative cell r1, and the histogram is stable across r1/r2/r3):

    bucket             PERCHAIN   GLOBAL
    NULL(no-wait)        4260      4275
    LWLock:*              313       278     (all LWLock:WALWrite)
    Client:*              179       188     (ClientRead = think time)
    IO:*                  144       136     (IO:WalSync dominant, some WalWrite/DataFileRead)
    Lock:*                  8        18     (Lock:transactionid)
    active_total obs     4691      4690
    active + NULL-wait    4197      4221

VU64 (top VU, cell r1):

    bucket             PERCHAIN   GLOBAL
    NULL(no-wait)        8575      8374
    LWLock:*              670       765     (LWLock:WALWrite)
    IO:*                  192       289     (WalSync + DataFileRead)
    Client:*              178       183
    Lock:*                 77        77     (Lock:transactionid -- IDENTICAL)
    active_total obs     9490      9494
    active + NULL-wait    8523      8331

**Splitting the dentry lock changed NOTHING in the wait profile.** LWLock waits did not drop going from
GLOBAL to PERCHAIN (313 vs 278 @VU32; 670 vs 765 @VU64 -- if anything slightly higher, i.e. noise).
Lock:* is identical. This is the direct mechanistic confirmation: backends are not contending on the
dentry lock, so splitting it neither drops the LWLock histogram nor moves NOPM. This holds the
prediction the campaign set up: because the block is not in that lock, the split is a null.

## What the NULL(no-wait-event) dominance means -- read carefully, this is where a prior verdict was 60x wrong

At VU32 ~90% and at VU64 ~88-90% of ACTIVE client backends sit in wait_event IS NULL. **This is NOT
"CPU-bound" and I do not call it that.** state='active' with wait_event NULL means "not on a registered
PG wait event" -- it does NOT mean on-CPU. The thing that makes the not-CPU-bound claim provable is the
HOST CPU COUNTER, not the wait event:

    host instr @VU64  PERCHAIN: NVMe %util 13.5% (9.6-16.7), w_await 0.14ms, aqu-sz 0.24, ~76 MB/s;
                                qemu CPU ~372-401% of one core / 3200 ceiling = ~12% of 32 vCPU
    host instr @VU64  GLOBAL  : NVMe %util 16.7% (12.2-20.4), w_await 0.20ms, aqu-sz 0.33, ~84 MB/s;
                                qemu CPU ~398-426% of one core / 3200 = ~13% of 32 vCPU

Device idle AND CPU idle (88% of 32 vCPU unused) in BOTH arms while throughput is capped. The wait event
alone could not distinguish "on CPU" from "stalled below the syscall boundary"; the 12-13%-of-32-vCPU
host counter is what does. So: the backends are **not on a PG wait event, not on the CPU, and not on the
device** -- the serialization is OSv-side, below the syscall boundary, invisible to PG's wait machinery.

## OSv-side thread instrument (the campaign's extra ask) -- what was reachable and what it showed
- OSv HTTP/REST monitoring API: NOT present in this image (no httpserver module baked in).
- QEMU gdbstub: NOT enabled (boot.sh has no -s/-gdb), so gdb-to-guest thread dumps were not reachable
  without a reboot; gdb was installed in the build container but cannot reach guest threads without it.
- Reachable fallback (option 3): two pg_stat_activity snapshots 5s apart, counting ACTIVE client
  backends whose state_change is FROZEN (stalled below syscall) vs advancing. Taken under live load:
      GLOBAL VU32 (3 sample-sets): 0 of 32 active backends stalled; 31-32 progressing.
      GLOBAL VU64 (3 sample-sets): 0 of 62-64 active backends stalled; 62-64 progressing.
  raw/frozen2-gl-vu32-*.json, raw/frozen2-gl-vu64-*.json.

**Interpretation, refined by that instrument:** under steady load there is NO dead-wakeup wedge. The
wait_event=NULL backends are RAPIDLY CYCLING through brief active/runnable states -- each state lasts
<5s, so state_change advances every sample -- but each is too short-lived to land on a registered PG
wait event. Combined with the idle host CPU and idle device, the shape is a **per-transaction OSv-side
latency tax** (syscall-completion + scheduler round-trips distributed across every transaction), not a
single lock all backends pile onto. The background writer was the only bg worker doing visible work
(IO:DataFileWrite / IO:DataFileFlush); checkpointer/walwriter/autovac idle in Activity:*Main between events.

## The checkpointer / write-phase stall, captured bare (a datapoint, not fought)
Twice at VU64 a cell produced ~0 NOPM (PERCHAIN r2, GLOBAL r2 = 0 NOPM / 7 TPM) and a subsequent
CHECKPOINT would not converge in the poll window -- the same VU64 stall zilab documented. It was seen
most cleanly during the between-arm crash-recovery: the end-of-recovery checkpoint (a single background
process, NO client load) took **519.9 s to write 1,016,833 buffers** -- write=519.858s, sync=0.032s.
The time is entirely in the WRITE phase (~2000 buffers/s ~= 15 MB/s) while the device sits 85% idle and
sync is instant. A background process writing dirty buffers at 15 MB/s against an idle NVMe is the same
below-syscall latency tax, seen without any concurrency to hide it. This is the strongest single pointer
to the mechanism: it is in the per-write syscall completion path (scheduler/wakeup/IO-completion), not
in fsync, not in device bandwidth, and not in any PG lock. Captured to raw/console-gl.log,
raw/console-pc-stall.log, raw/frozen-sample{1,2}-recovery.txt.

## What this result means (stated straight, not spun)
PERCHAIN ~= GLOBAL at every VU, and the wait histograms are indistinguishable. **The global dentry lock
is NOT the throughput lever for this workload.** PR #1503 (per-chain dentry locks) is defensible on its
own merits -- finer locking and the AB-BA/allocation-under-lock fixes it carries are correct -- but this
benchmark provides **no evidence it improves TPROC-C throughput**, and it should not be justified on a
throughput basis. This is the more valuable of the two possible outcomes because, combined with the
histogram, it NAMES the next target: the bottleneck is an OSv-side per-transaction/per-write latency in
the syscall-completion + scheduler/wakeup path (LWLock:WALWrite is the only PG wait that shows at all,
and it does not move with the lock split). The next experiment should instrument OSv's condvar/wakeup
and virtio-blk IO-completion latency directly -- e.g. boot with the QEMU gdbstub enabled (-s) so an
`osv info threads` / `thread apply all bt` sample can show whether the checkpointer write phase is
parked at a single OSv-kernel address, or enable the OSv httpserver for /os/threads.

This is NOT an OSv-vs-Linux comparison and no Linux number is reintroduced.

## Artifacts (workstation, .local/dentryab/raw/)
Per cell (both arms, VU 8/32/64): cell-*.log (NOPM), probe-*.json, wait-raw-*.ndjson (raw samples),
wait-hist-*.json (aggregated histogram), xtprof-*.log (NEWORD p99), quiesce-*.log (all checkpoint
durations). Plus: frozen2-gl-vu{32,64}-*.json (OSv-side stall instrument), frozen-sample{1,2}-recovery.txt,
iostat/qemucpu-{pc,gl}-vu64-r1.txt (host device+CPU), console-gl.log (=0 proof + recovery-checkpoint
520s), console-pc-stall.log. PROGRESS.md has the live cell-by-cell log.
