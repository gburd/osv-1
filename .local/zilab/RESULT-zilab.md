# ZIL hires-cv A/B on OSv: does honouring the sub-ms commit-batch window change PostgreSQL throughput?

**Answer: NO. It is a null result.** Toggling `OSV_ZFS_HIRES_CV` on vs off moves TPROC-C NOPM
by +3.4% / +0.1% / +2.9% at VU 8 / 32 / 64 -- every delta is inside the 3-4% run-to-run spread and
none is close to the 15% flag threshold. ZIL commit coalescing is **not** the throughput lever for
this workload on this substrate.

## Box ids (Owner=agent-zilab, account 769093516156 lava, us-east-2) -- BOTH TERMINATED (see end)
    METAL host (OSv guest)  i-035bbc5224b0eecbf  m5d.metal    priv 172.31.5.80  pub 13.59.94.13
    DRIVER   (HammerDB)     i-01869557eb2764838  c5.4xlarge   priv 172.31.8.64  pub 3.138.116.180

## The one variable, and the proof it bound
ONE image (`gh-fork/bench/zil-hires-ab-v2`, OSV_SHA=c96c16a9), ONE pool, ONE 19 GB dataset, ONE guest
(32 vCPU / 64 GiB), identical GUCs. The arms differ only by a boot `--env`, read once per boot in
`bsd/porting/netport1.cc:139` and announced on the console:

    arm ON  (--env=OSV_ZFS_HIRES_CV=1):  ZFSFLAG OSV_ZFS_HIRES_CV=1 (set)   -> cv->wait(nanoseconds(delta_ns))  honours the sub-ms deadline
    arm OFF (--env=OSV_ZFS_HIRES_CV=0):  ZFSFLAG OSV_ZFS_HIRES_CV=0 (set)   -> ticks=delta_ns/(1e9/hz)=0 for a 250us window -> cv_timedwait(0) returns immediately

Both console lines are captured (raw/console-on-arm.log, raw/console-off-arm.log). The two arms printed
DIFFERENT values -> the A/B is valid, not void.

## Base guards verified (from the container build log, before compiling)
    OSV_SHA=c96c16a94472a854848adc018dde4e74a57f473b   (branch tip, exact)
    APPS_SHA=3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3   (seed_copy rofs fix; PHONY_COUNT=1)
    ZFS_SHA=6330a45b06d20125de679aae5f63ba14082671ef
    stack_guard=3   OSV_FORK_RANGE_BS=2   OSV_FORK_LARGE_SHARE=2   (all as required)
    image usr.img 114 MiB qcow2 rofs (not the 8 MB PG-free failure); PG binary + seed_copy + ZFS .so set present

## Config, identical on both arms (verified from the driver as source='command line')
PG 18.6 musl, 200 warehouses / 19 GB on ZFS-on-NVMe (ashift=12, recordsize=8k, compression=off,
atime=off, sync=standard, logbias=latency, primarycache=all -- read back via `zpool/zfs get`).
GUCs: max_connections=400, shared_buffers=16GB, effective_cache_size=32GB, max_wal_size=64GB,
min_wal_size=2GB, checkpoint_timeout=15min, checkpoint_completion_target=0.9, log_checkpoints=on,
fsync=on, synchronous_commit=on, autovacuum=on, io_method=sync. All 12 = source 'command line'.

## HEADLINE

    VU    ON median   OFF median   delta%   ON/OFF ratio
    8       48,758      47,144      +3.4%      1.034
    32      37,012      36,957      +0.1%      1.001
    64      33,864      32,910      +2.9%      1.029

All deltas <= the run-to-run spread (3.0-3.6%). No delta exceeds 15%. NULL.

## Per-cell detail (NOPM; 3 settled repeats per arm, quiesced before each)

    VU8   ON : 49100, 48758, 47459   median 48758  spread 3.4%
    VU8   OFF: 46452, 47836          median 47144  spread 2.9%   (r1=115988 VOIDED -- false quiesce, see below)
    VU32  ON : 38051, 36713, 37012   median 37012  spread 3.6%
    VU32  OFF: 36957, 36979, 36199   median 36957  spread 2.1%   *** cleanest pair: delta +0.1% ***
    VU64  ON : 33396, 33864, 34416   median 33864  spread 3.0%
    VU64  OFF: 32910                 (1 valid; r2/r2b failed/stalled, see below)

Console ZFSFLAG per cell-group:
    all ON cells  served by boot console-on-arm.log :  ZFSFLAG OSV_ZFS_HIRES_CV=1 (set)
    all OFF cells served by boot console-off-arm.log:  ZFSFLAG OSV_ZFS_HIRES_CV=0 (set)

num_requested vs num_timed: HammerDB `pg_num_vu`=VU, `vucomplete` polled (runtimer deprecated);
`VUCOMPLETE_AFTER 0 s` on every good cell means all timed vusers drained before vudestroy.

NEWORD p99 (xtprof aggregate, ms):
    VU8   ON 11.26   OFF 15.03-15.81
    VU32  ON 45.91   OFF 51.34
    VU64  ON 107.26  OFF 115.11
(OFF slightly higher latency at every VU, but throughput unchanged -- consistent with a null on NOPM.)

Connect probe (fresh connect+select 1, alone in the timed window; 300 samples/cell):
    VU8  ON  median 42ms  p99 56ms   0 errors, 0 >=1s
    VU32 ON  median 72ms  p99 143ms  |  OFF median 72ms p99 126ms   0 errors, 0 >=1s
    VU64 ON  median 122ms p99 194ms  |  OFF median 138ms p99 201ms  0 errors, 0 >=1s

## VU32 instrumentation (device + guest CPU during the timed window)
    ON  (r3): iostat %util median 10.5% (7.2-14.7), w_await 0.13ms, aqu-sz 0.21, wkB/s ~83 MB/s
              qemu CPU ~400-437% of one core / 3200 ceiling  = ~13% of 32 vCPU
    OFF (r2): iostat %util median 15.2% (12.1-24.0), w_await 0.13ms, aqu-sz 0.28, wkB/s ~98 MB/s
              qemu CPU ~459-485% of one core / 3200 ceiling  = ~14.5% of 32 vCPU
Both arms: the NVMe is ~10-15% busy and the guest uses ~13-15% of its vCPUs -- **device idle AND CPU
idle** while throughput is capped. Top wait: WALWrite/commit-side, but the bottleneck sits on neither
the disk nor the CPU. This is the same unattributed stall a2abench7 flagged, and the ZIL flag does not
touch it.

## Two thrown-out cells (recorded, not massaged away)
1. OFF-VU8-r1 = 115,988 NOPM -- VOIDED. Its quiesce log shows a single `checkpoint 1: 0.079s`. It ran
   immediately after the ~8 min crash-recovery (below), which had just checkpointed, so the first
   CHECKPOINT returned fast while a large dirty backlog remained; the run then drained that backlog and
   read 2.4x high. Exactly the a2abench7 failure mode (their 80,417). Every properly-settled cell shows
   the correct signature: several ~120-500s checkpoints, then a sub-1s one. I hardened the quiesce to
   require TWO consecutive sub-1s checkpoints after seeing this.
2. OFF-VU64-r2 = 0 NOPM / 125 TPM, and the re-run r2b + r3 could not be completed: after repeated VU64
   load the guest entered a state where a single CHECKPOINT would not converge within 900s (console
   shows a `checkpoint starting: time` at 23:09 that never printed `checkpoint complete`), while PG
   still answered `select 1`. The checkpointer stalled -- the same idle-device/idle-CPU stall seen at
   VU32. I have one properly-quiesced VU64-OFF point (32,910, quiesce cp1-5 slow then cp6 0.081s), which
   with the 3 VU64-ON points is enough to place the delta at +2.9%, in line with VU8 and VU32.

## Confounds held constant / notes
- The ~8 min PG crash-recovery when switching ON->OFF was caused by an unclean guest kill (a brief
  window where the old ON QEMU had not died before the OFF QEMU started -- 2 QEMU on one pool disk).
  Caught immediately, both killed, ONE clean OFF guest booted. ZFS checksums were clean and PG replayed
  WAL to a consistent state: 200 warehouses, 19 GB intact afterward. This affected only the timing of
  when OFF cells could start, not the dataset -- and the fsync/synchronous_commit durability that made
  recovery succeed is itself held identical across arms.
- FORKFLAG runtime env (OSV_FORK_RANGE_BS/LARGE_SHARE) defaulted to 1 on BOTH arms (unset) -- constant,
  not a confound. The =2 the brief names is the source-level guard grep count, which passed.
- ARC 32 GiB (guest 64 / base caps at half): constant across arms, irrelevant here as the brief states.

## What this means (stated straight)
ON approx OFF. **ZIL commit coalescing is NOT the throughput lever for this workload on OSv.** The
~sub-ms `cv_timedwait_hires` deadline being honoured (fixed) vs rounded to zero ticks (old) changes
NOPM by less than the measurement noise at every concurrency level tested. The per-transaction cost that
holds OSv's TPROC-C throughput down lives elsewhere -- the WAL write path / virtio-blk flush / ZFS write
amplification / the idle-device idle-CPU checkpointer stall -- not in ZIL batch-window timing.

Consequence for PR #1505 (which ports this fix to master): the fix is correct on its own merits
(honouring a requested sub-ms deadline is the right behaviour, and standalone it does wait the true
250us window), but this benchmark provides **no evidence that it improves TPROC-C throughput**, and
should not be justified on a throughput basis. If #1505 is landed it is on correctness grounds, not
because it moves this number.

This is NOT an OSv-vs-Linux comparison and no Linux number is reintroduced.

## Artifacts (workstation, .local/zilab/raw/)
on-raw.tgz, off-raw.tgz (all hdb-*.log, probe-*.json, xtprof-*.log, quiesce-*.log per cell),
iostat/qemucpu-{on,off}-vu32-*.txt, console-{on,off}-arm.log. PROGRESS.md has the live cell-by-cell log.
