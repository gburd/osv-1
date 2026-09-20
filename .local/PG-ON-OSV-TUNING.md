# PostgreSQL on OSv: tuning

**CORRECTIONS FROM THE 2026-09-07 CAMPAIGN - READ BEFORE QUOTING ANY NUMBER IN THIS DOC.**

1. **The "ZFS COW caps ~500-530 MB/s" figure in this doc is ~9x TOO OPTIMISTIC.** Measured
   on x86 bare metal with the mandated production config: **59.9 MiB/s aggregate**
   (20463 MiB / 341.7 s across three checkpoints). Host device does 883 MB/s at 1 MiB
   direct but only **107 MB/s at 8 KiB direct+dsync**, so the guest reached ~56% of
   achievable. `sync` was 0.020 s throughout: **fsync is cheap, the WRITE phase dominates.**
2. **The two ISAs hit DIFFERENT walls. Do not merge them.** x86 hit ZFS COW write
   amplification at recordsize=8k against an 8K-sync device ceiling. aarch64 hit
   `LWLock:WALWrite` on 20-31 of 32 backends with the NVMe **98% IDLE** (%util 1.34-2.80) -
   a guest software serialization, not storage.
3. **Fresh-connect latency is much better than previously briefed**: 262 ms median /
   501 ms max / **zero samples >=1 s** at VU8 on x86. The "65-150 ms fork x concurrency =
   multi-second floor" estimate overstated it. The VU32 gate is **UNTESTED**, not passed.
4. **All benchmark numbers older than 2026-09-07 have unrecoverable provenance** on the x86
   lineage: the `apps` submodule pin was dangling, so the recorded tree was unbuildable.
   Result identity is now the triple **(osv SHA, apps SHA, zfs banner)**.
5. **A blocking kernel bug makes HammerDB unrunnable on both ISAs** (different bugs, same
   backtrace shape). See ELF-RECLAIM-BUG-CONFIRMED.md (x86, reclaim-vs-dlsym, reproducer
   exists) and AARCH64-DLOPEN-FAULT.md (aarch64, deterministic vm_fault populate failure).

# Tuning PostgreSQL on OSv over ZFS

Operator guide for running stock PostgreSQL on the OSv unikernel with OpenZFS on
local NVMe, on bare-metal instances and under Firecracker. Every number here is
MEASURED on x86_64 (m5d-class bare metal, KVM); see the "Architecture coverage"
section for the aarch64 status (compiles + boots, NOT yet benchmarked).

This is a living document. Update it when a new lever is measured. Keep the
"validated" vs "hypothesis" distinction honest: a setting only moves from the
hypothesis list to the validated table with a pasted A/B behind it.

---

## 1. TL;DR: the config that matters

Start here; the rest explains each line. NOTE the two profiles below differ
deliberately: a BENCHMARK profile (fixed for reproducible A/B) and a PRODUCTION
profile (what you actually run) -- see section 2 for why (autovacuum, shared_buffers).

Start here; the rest of the doc explains each line.

Boot cmdline (append to the OSv loader):
    --env=OSV_WAKE_LOCAL=0 \
    --env=OSV_WAKE_PULL=1 \          # ONLY if virtual users > vCPU count (see 4.2)
    <zpool create ...> ; <postgres ...>

ZFS pool (single dataset, simplest; see 3.2 for the recordsize split):
    zpool create -f -o ashift=12 \
      -O compression=off -O atime=off -O recordsize=8k \
      -O sync=standard -O logbias=latency -O primarycache=all \
      -m /data pgdata /dev/vblkN

PostgreSQL args -- BENCHMARK profile (fixed for reproducible A/B, NOT production):
    -c listen_addresses=* \
    -c max_connections=400 \
    -c shared_preload_libraries=plpgsql \
    -c autovacuum=off \           # BENCHMARK ONLY; production keeps it ON (see 2)
    -c max_wal_size=16GB \
    -c checkpoint_timeout=1h \
    -c shared_buffers=8GB \        # fixed A/B point; production sizes to RAM (see 2)
    -c max_files_per_process=200

PostgreSQL args -- PRODUCTION profile (the real starting point):
    -c listen_addresses=* \
    -c max_connections=<your workload> \
    -c shared_preload_libraries=plpgsql \
    -c autovacuum=on \            # keep ON; correctness (bloat, xid wraparound)
    -c shared_buffers=<~25% of guest RAM, capped so ARC(half RAM)+backends fit> \
    -c effective_cache_size=<shared_buffers + expected ARC> \
    -c max_wal_size=<sized to write rate; << 16GB is fine> \
    -c checkpoint_timeout=<5-15min; spread the I/O, do not stack> \
    -c max_files_per_process=200 \   # keep: bounds fds under OSv's global table
    -c synchronous_commit=on

## 1a. Build instructions (x86_64)

fedora:39 toolchain (native or container). conf_fork=1 (PostgreSQL needs
fork()) and conf_zfs=openzfs (OpenZFS, not the legacy bsd ZFS) are the key knobs.

    git clone https://github.com/gburd/osv-1.git osv && cd osv
    git fetch origin wip/pg-zfs-bench-v24 && git reset --hard FETCH_HEAD  # see 1b
    git submodule update --init --force \
        musl_1.2.1 musl_0.9.12 external/x64/acpica kbuild modules/open_zfs/openzfs
    # apps = github.com/gburd/osv-apps @ wip/postgres18-musl-demo
    # apply the OpenZFS patches (--recount if a hunk drifts):
    touch modules/open_zfs/openzfs/.osv-patches-applied
    ( cd modules/open_zfs/openzfs && git reset --hard HEAD && git clean -fdx
      for p in ../patches/*.patch; do
        git apply --whitespace=nowarn "$p" || git apply --recount --whitespace=nowarn "$p"
      done )
    # toolchain: gcc gcc-c++ libstdc++-static glibc-static musl-gcc musl-devel
    #   perl-interpreter perl-FindBin perl-lib perl-File-Compare perl-File-Copy
    #   util-linux shadow-utils zlib-devel qemu-img qemu-system-x86-core
    # with fs=ramfs, build the ZFS .so set FIRST (bootfs needs them), then image:
    make -j$(nproc) conf_fork=1 conf_zfs=openzfs fs=ramfs \
        build/release.x64/{libsolaris.so,zpool.so,zfs.so} \
        build/release.x64/tools/mount/{mount-fs.so,umount.so}
    ./scripts/build -j$(nproc) conf_fork=1 conf_zfs=openzfs fs=ramfs \
        image=open_zfs,zfs,zfs-tools,postgres18-musl
    # output: build/release.x64/loader-stripped.elf

aarch64: builds but does not yet serve queries -- see section 8 (frontier).

## 1b. Where the fixes live (branch state)

The combined fix stack is NOT on any master. Our fork (github.com/gburd/osv-1)
master tracks upstream; each fix is a separate upstream PR against
cloudius-systems/osv:master so it reviews one at a time (#1481 #1483 #1484 #1485
#1486 #1487 #1488 #1472, plus the CONF_fork-gated fork-stack after #1455). The
single "everything integrated and tested together" branch is
wip/pg-zfs-bench-v24 -- that is what 1a builds. No integrated master exists yet;
that is deliberate (upstream one reviewable PR at a time). When the PRs merge,
upstream master carries the set.

---

## 2. The OSv-specific settings and WHY (not standard PG tuning)

- `shared_preload_libraries=plpgsql` -- load plpgsql BEFORE the postmaster
  forks, so every backend inherits it. Without this, a forked backend that
  dlopen()s plpgsql can crash on the fork-COW dlopen path. This is a
  benchmark-cleanliness setting while the fork-stack fixes land upstream, not a
  perf hack.
- `autovacuum=off` (BENCHMARK ONLY) -- disabled ONLY for reproducible A/B runs:
  it removes the autovacuum-launcher/worker forks so the timed window is not
  perturbed by background fork churn. PRODUCTION MUST run autovacuum ON (else
  table bloat and eventual xid-wraparound). Autovacuum ON is VALIDATED to work
  on OSv/PG-on-ZFS: measured crash-free through VU128 with the launcher + 3
  workers forking continuously under HammerDB load (fd-limit fix PR #1485 is
  what lets it past the old VU64 EMFILE wall). It costs throughput vs OFF
  (aggressive naptime competes for I/O: ~-35% at VU32, more at higher VU) --
  tune autovacuum_naptime/max_workers for your workload. Beyond ~VU96 the
  combined autovac-fork + checkpoint + shared_buffers memory demand can hit the
  OSv reclaimer OOM (see section 5); keep shared_buffers + ARC sized to fit.
- `shared_buffers=8GB` was a FIXED A/B point for the 40-warehouse dataset, not a
  tuning claim. In production size it to the guest (~25% of RAM is the usual
  start) but remember the ARC also lives in this RAM (capped at half, PR #1487),
  so shared_buffers + ARC + backend working sets must fit; on a small guest keep
  it modest (2 GiB).
- `max_wal_size=16GB` + `checkpoint_timeout=1h` (BENCHMARK) spread checkpoints
  out so they do not stack during a short timed run. Production wants smaller,
  more frequent checkpoints (5-15 min) sized to the write rate, so I/O is spread
  and a single checkpoint cannot stack enough dirty data to pressure memory.
- `max_files_per_process=200` -- caps per-backend open fds so hundreds of
  backends stay under OSv's global fd table (raised to 65536, PR #1485). Without
  it, a long many-connection run can exhaust the table and the WAL writer PANICs
  with EMFILE.
- `ashift=12` -- 4K sectors, matches NVMe.
- `recordsize=8k` -- matches the PG page (one ZFS record per page write, no
  read-modify-write). See 3.2 for splitting WAL onto a larger recordsize.
- `sync=standard`, `logbias=latency` -- honor fsync durably through the ZIL.
- `compression=off` -- for A/B isolation; a real deployment likely wants lz4.

---

## 3. ZFS layout levers

### 3.1 Single dataset (default)
The TL;DR pool: one recordsize=8k dataset for data and WAL. Simplest, and on
AWS instance-store NVMe it is within noise of the split (see 3.2 why).

### 3.2 Recordsize split (data 8k / WAL large) -- the known ZFS-PG pattern
    zpool create -f -o ashift=12 -O compression=off -O atime=off \
      -O sync=standard -O primarycache=all -O recordsize=8k -m /data pgdata /dev/vblkN
    zfs create -o recordsize=8k -o mountpoint=/data/base pgdata/base
    zfs create -o recordsize=1M -o logbias=throughput -o mountpoint=/data/wal pgdata/wal
    # initdb -D /data/base --waldir=/data/wal
WAL is a large sequential stream into 16MB segments; 8k records fragment it and
cause write-amplification, so WAL wants a larger recordsize (64k-1M).

MEASURED CAVEAT (x86_64, AWS instance-store): the split was NULL (~+6%, noise)
because that NVMe reports vwc=0 (no volatile write cache) -- the per-commit ZFS
cache flush is a device no-op, so there is little write-path cost for the split
to remove. KEEP THE SPLIT on a REAL device (vwc=1, e.g. EBS or physical NVMe
with a write cache) where each commit flush is a real round-trip; it is only a
no-op on cache-less instance-store. Check with `nvme id-ctrl <dev> | grep vwc`.

### 3.3 ARC sizing
The ARC and the application share one physical address space on OSv. The
default ARC cap is half of RAM for guests > 2 GiB (PR #1487) so PostgreSQL
(shared_buffers + backends) always keeps at least half the guest. On a small
guest keep shared_buffers modest (2 GiB) so the ARC + buffer pool + backends fit.

---

## 4. The scheduler levers (the ones that actually moved high-VU throughput)

### 4.1 The finding: high-VU collapse was a scheduler problem, not a WAL wall
On AWS instance-store (vwc=0) the WAL flush is free and write_time is ~0. The
per-commit floor is the intrinsic cross-CPU wake IPI/VM-exit cost (a single
synchronous commit stream cannot be coalesced -- QD1 is irreducible here). The
NOPM COLLAPSE past the vCPU count was NOT a storage wall: it was the scheduler
failing to disperse the single ZIL/commit waker's fan-out, so backends piled
onto ~8-10 vCPUs while the rest sat halted.

### 4.2 OSV_WAKE_PULL=1 -- the high-concurrency knob (VALIDATED)
Idle-CPU pull / work-stealing (PR #1472). Arm it when virtual users EXCEED the
vCPU count. MEASURED (x86_64 m5d-metal KVM, 32-vCPU guest, 40wh, clean-pool A/B):

  HammerDB TPROC-C NOPM, WAKE_PULL off -> on:
    VU16  14149 -> 15026  (+6%)
    VU32  26722 -> 30087  (+13%,  = vCPU count)
    VU64   7989 -> 27009  (+238%)
    VU96   7485 -> 25697  (+243%)
    VU128  7336 -> 24821  (+238%)
  pgbench TPC-B: 64 clients +191%, 96 +60%.
  vCPU busy (VU64): off R=8-10/S=26 (collapsed); on R=29-30/S=5 (spread).

TRADEOFF (why it is opt-in, default off): at/below the vCPU count it is a
wash-to-slight-loss (QD1 -14%, N8 -6%) -- with few runnable threads the pull
IPIs are pure overhead. Turn it ON for oversubscribed OLTP (VU > vCPU), OFF for
low-concurrency / latency-sensitive workloads. It restores throughput and
UTILIZATION, not per-op latency (p99 is ~flat across both arms; this workload
is latency-bound on the 8k recordsize).

### 4.3 OSV_WAKE_LOCAL -- do NOT use for the ZIL commit path
An attempt to wake the committing backend on the waking CPU (push-retarget)
CRASHED the runqueue (unsafe on the wait-morphing path). Leave OSV_WAKE_LOCAL=0.
The safe lever is OSV_WAKE_PULL (4.2).

### 4.4 OSV_IDLE_SPIN -- optional
Longer idle spin catches a wake before halting (avoids the halt/wake VM-exit),
helps at the guest exit-rate ceiling; burns cycles on a genuinely idle system.
Server images can raise it (`--env=OSV_IDLE_SPIN=100000`); measure per workload.

---

## 5. Memory pressure at very high VU

The OSv memory reclaimer OOMs the guest if a shrink pass frees nothing. Two
fixes make the ARC give memory back under pressure instead of the guest
aborting: (1) the synchronous hard-mode ARC shrinker (PR #1487) waits for
eviction to actually free memory instead of only lowering the target; (2) the
retry-reclaim change (wip/pg-zfs-bench-v25, core/mempool.cc) keeps shrinking as
long as each pass frees memory (up to 16 passes) and only OOMs when a pass frees
zero. A single pass frees only a slice, so one pass could come up short for a
large waiter while the ARC was still full. Together these moved the
autovacuum-ON crash-free wall from VU128 to past it (survives VU128 with
autovacuum running, ~16k NOPM), measured on x86_64.

Beyond ~VU128 (autovacuum ON) / VU192 (OFF) the guest can still OOM, but it is
now a DIFFERENT failure: a genuine over-commit / large-contiguous-allocation
wall, not premature give-up. The 16 retry passes are exhausted yet ~24-31 GB of
48 GB is still free, so a large physically-contiguous request cannot find a run.
Mitigate by sizing the guest for the workload (8 GB shared_buffers + ARC + 192
forked backends on a 48 GB guest is tight), lowering shared_buffers, or capping
the ARC harder; a page-allocator anti-fragmentation / contiguous-reclaim lever
is the deeper fix if you must push past it. For production, keep shared_buffers
+ ARC well under guest RAM and this wall stays out of reach.

---

UPDATE (measured, x86_64, v26 = v25 retry-reclaim + PR #1487 synchronous ARC
shrinker, both compiled in): VU192 no longer OOMs in any config tried --
autovacuum OFF at 48G/8GB and at a tight 32G/16GB, single and back-to-back
runs, all rode through VU192 with NO 'Out of memory' / no abort. The two mm
fixes together turned the former VU192 crash into a graceful THROUGHPUT decline
(NOPM fell ~67k -> ~9k across back-to-back runs on the tight heap as
fragmentation accumulated) -- the reclaimer always freed real memory before
declaring OOM. So at extreme scale PG-on-OSv-ZFS DEGRADES, it does not crash.
The OOM path now carries a diagnostic (largest contiguous free range vs total
free) so any residual OOM at even higher scale is characterizable; to actually
reach it you must push past VU192 or defeat the shrinker. Bottom line: crash-
free through VU192 (OFF) and VU128 (autovacuum ON); beyond that it is a
throughput/fragmentation cost, not a correctness failure.

---

## 6. Running on bare-metal instances (KVM)

- MUST be a bare-metal instance (has /dev/kvm). A non-metal instance falls back
  to TCG software emulation (~10-50x slower, useless for timing). Verify
  `ls -l /dev/kvm`.
- Use local instance-store NVMe for the ZFS pool (not EBS root) for the data.
- OSv caps at 64 CPUs; size the guest `-smp` to the physical cores you want
  (32 is a good OLTP point; going wider hits the wake-dispersal issue -> arm
  OSV_WAKE_PULL).
- Native NVMe appears as vblkN in the guest; a virtio-blk data disk also works.
- Fresh boot per VU sweep (or per few points): fds and pool state accumulate
  across back-to-back runs. Re-seed or import the pool per boot.

## 7. Running under Firecracker (micro-VM)

VALIDATED (x86_64, Firecracker v1.10.1, 16-vCPU guest, 40wh):
  VU8=113323 NOPM (2.9x Linux VU8), VU16=145073 (peak), VU32=136521.

- Boot OSv with `--nopci` boot_args (Firecracker has no PCI; uses MMIO virtio).
- rootfs on vblk0, ZFS data pool on vblk1; tap networking (e.g. 172.16.0.1/30
  host, guest 172.16.0.2).
- `zpool create -f` in the boot chain wipes /data each boot, so re-seed the
  schema per boot (or attach a pre-populated data disk read-write).
- Firecracker's virtio exposed two OSv guest crashes at high VU not seen on
  bare-metal KVM: a rare ARP-callout NULL-deref (fixed: PR #1486 callout
  dispatcher use-after-free) and an ARC OOM at VU64 on a too-small (32 GB)
  guest (fix: cap the ARC / bigger guest / patch 0032). Use a guest sized for
  the VU count and the vNN branch with those fixes.
- Same scheduler guidance as bare metal: arm OSV_WAKE_PULL=1 when VU > vCPU.

---

## 8. Architecture coverage: x86_64 vs aarch64 -- HONEST STATUS

- x86_64: FULLY benchmarked. Every measured number in this doc and in
  HAMMERDB-BENCHMARK.md / ROADMAP.md is x86_64 on m5d-class bare metal (KVM) or
  Firecracker.
- aarch64: NOW BUILDS, BOOTS under KVM, and SERVES QUERIES on bare-metal
  Graviton3 (c7gd.metal). PostgreSQL 18.6-on-ZFS reaches "ready to accept
  connections" and runs pgbench (-c4 -T30 on a real ZFS pool = 78,577 tx, 0
  failed, ~2190 tps) -- sustained forked backends + ZFS commits on aarch64,
  first-ever. The fork-COW infinite page-fault loop is fixed: OSv aarch64 uses a
  split TTBR (everything in TTBR0), and four bugs were root-caused and fixed --
  the per-process page-table root was ignored, TTBR0 was not switched on context
  switch, the fork caller-context capture was wrong, and fork timer-park was
  missing on the aarch64 scheduler. Work is on branch wip/aarch64-forkcow (8
  commits on top of the x86 v24 stack; currently unsigned, to be re-signed for a
  PR).
  Known limits: runs at <=3 GB RAM for now (a separate setup_temporary_phys_map
  bug hangs the guest at >=4 GB), and a fs=zfs ROOTED image needs a nested-KVM
  zfs_builder (runtime `zpool create` is used instead). No aarch64-vs-x86_64
  speed comparison yet -- fix the >=4 GB map first, then benchmark at scale.

Remaining aarch64 work to reach parity testing: (1) fix setup_temporary_phys_map
to cover >=4 GB so the guest can run realistic RAM; (2) re-sign the
wip/aarch64-forkcow commits and split them into reviewable PRs; (3) run the
bare-metal recipe (section 6) at scale on aarch64 and produce an
aarch64-vs-x86_64 table. The parity/M1 story is x86_64; aarch64 is now a
working second ISA, not yet a benchmarked one.

---

## 9. Baselines (for comparison)

- Linux PG16-on-ZFS, x86_64 m5d-metal, 40wh: VU8=38948, VU16~44.5k, VU32~45.5k,
  VU64~40.8k NOPM (~45k plateau, CPU-bound at this small dataset).
- Linux PG16 800wh (right-sized, I/O-bound): ext4 ~181k @ VU192, ZFS ~112-127k
  (ZFS COW write-amp caps WAL ~500 MB/s vs ext4 ~766 MB/s). CPU stays 85-92%
  idle -- the wall is WAL write throughput + LWLock:WALWrite, not CPU.
- OSv PG18.6-on-ZFS x86_64 (crash-free, v19+): VU16~67.5k peak at 40wh (~1.73x
  Linux VU8); with OSV_WAKE_PULL, sustained ~25k past VU64 instead of collapse.

Cross-reference: HAMMERDB-BENCHMARK.md (full runbook + results),
WAL-ZIL-THROUGHPUT-PLAN.md (the write-path investigation), ROADMAP.md (the
chronological measured record and fix stack).

---

## 10. Per-instance-type / hypervisor tuning (measured + how it generalizes)

All numbers are MEASURED PostgreSQL-18.6-on-OpenZFS, 40-warehouse HammerDB
TPROC-C, ZFS on local instance-store NVMe, guest sized to the host. "Best
knob-set" is the config that gave the highest crash-free throughput / most
stable latency on that platform.

### 10.1 x86_64 bare-metal + QEMU-KVM (m5d-class .metal, 96 cores)
The reference platform. All the deep fixes were found here.
- Guest: `-accel kvm -cpu host -smp 32 -m 48G`. 32 vCPUs is the OLTP sweet spot;
  going wider needs OSV_WAKE_PULL (below) or throughput collapses past the vCPU
  count. OSv caps at 64 vCPUs regardless.
- Best knob-set: `--env=OSV_WAKE_PULL=1` (essential once virtual users exceed
  vCPUs), default idle-spin, ZFS `ashift=12 recordsize=8k sync=standard
  logbias=latency`, PG `shared_buffers=8G` (benchmark) / ~25% RAM (production).
- Measured: peak ~248k NOPM @ VU32 (fresh), ~169k @ VU16; with OSV_WAKE_PULL,
  sustained ~25-27k past VU64 instead of the ~7.5k collapse; p99 ~8ms at VU16
  rising to ~250-300ms deep in oversubscription (latency-bound on 8k recordsize).
- Latency lever: p99 is dominated by the WAL/ZIL commit path + storage record
  size, NOT the scheduler. OSV_WAKE_PULL restores THROUGHPUT, not tail latency.
  For lowest p99, keep VU near vCPU count and the working set in shared_buffers.
- vwc=0 on AWS instance-store NVMe -> the per-commit ZFS cache flush is free, so
  the WAL recordsize-split and flush-oriented knobs are a no-op HERE (see 3.2).

### 10.2 x86_64 Firecracker micro-VM (m5d-class .metal host, 16-vCPU guest)
Fastest per-vCPU result measured; the micro-VM path.
- Guest: Firecracker v1.10.1, 16 vCPU / 32 GB, boot ~140-170 ms. boot_args
  `--nopci` (FC has no PCI; virtio-MMIO), rootfs=vblk0, ZFS data=vblk1, tap net.
- Best knob-set: same OSV_WAKE_PULL=1 for VU>vCPU; SIZE THE GUEST for the ARC --
  FC exposed the unbounded-ARC OOM at VU64 on a 32 GB guest (fixed by the
  half-RAM ARC cap PR #1487 + the sync shrinker); a bigger guest or a harder ARC
  cap avoids it. `zpool create -f` in boot_args wipes /data each boot, so
  re-seed the schema per boot or attach a pre-populated data disk.
- Measured: VU8=113,323 NOPM (2.9x the Linux VU8 baseline), VU16=145,073 (peak),
  VU32=136,521; p99 6.28ms @ VU8, 10.23ms @ VU16, 28.53ms @ VU32.
- Why so fast per-vCPU: FC's thin device model + no PCI + tight vCPU pinning cut
  per-exit overhead. Trade-off: FC's virtio-MMIO has a lower absolute ceiling
  than QEMU vhost at very high queue depth, and its virtio exposed two guest
  crashes not seen on QEMU-KVM (a rare ARP-callout NULL-deref, fixed PR #1486;
  an ARC OOM on an under-sized guest, fixed by #1487 + sync shrinker). Use a
  guest sized for the VU count and a build with those fixes.

### 10.3 aarch64 bare-metal (Graviton3, c7gd.metal, 64 cores)
Works (builds, boots under KVM, SERVES queries) but NOT yet performance-tuned.
- Guest: `-accel kvm -cpu host -machine virt -smp 32 -m <=3G>` (a
  setup_temporary_phys_map bug hangs the guest at >=4 GB -- fix that before
  scale-testing). The Graviton3 generic timer is 1.05 GHz (the cntfrq cap was
  raised to 2 GHz to accept it).
- Measured: pgbench -c4 -T30 on ZFS = 2190 tps, 0 failed (correctness proof,
  not a tuned throughput number). No HammerDB VU sweep yet (blocked by the >=4 GB
  RAM limit). Branch: wip/aarch64-forkcow-signed.
- Expected once un-blocked: the SAME knob-set as x86_64 (OSV_WAKE_PULL for
  VU>vCPU, ashift=12/recordsize=8k, ARC cap) should apply -- the scaling walls
  (wake dispersal, reclaimer OOM) are ISA-independent scheduler/mm behavior, so
  the fixes carry over. Graviton's higher core count (64) means the wake-
  dispersal lever (OSV_WAKE_PULL) matters even more.

### 10.4 How these generalize to other instance types
- **Any bare-metal x86 (i3en/i4i/m6i/m7i .metal, more cores/NVMe):** start from
  10.1. More cores -> OSV_WAKE_PULL is more important (bigger idle-vCPU pool to
  disperse into). More/faster NVMe raises the storage ceiling but the WAL/ZIL
  commit path (LWLock:WALWrite + wake latency) is the OLTP wall, not raw IOPS,
  so device speed helps read-heavy more than commit-heavy.
- **Instances with a REAL volatile write cache (vwc=1: EBS-backed, some physical
  NVMe):** UNLIKE instance-store (vwc=0), the per-commit ZFS cache flush costs a
  real round-trip -> the WAL recordsize-split (3.2), logbias, and a separate SLOG
  device DO help there. Re-enable those knobs; check `nvme id-ctrl <dev>|grep vwc`.
- **Smaller guests (fewer vCPUs, less RAM):** OSV_WAKE_PULL is a wash-to-slight-
  loss below the vCPU count -> leave it OFF. Size shared_buffers + ARC well under
  RAM (the ARC half-RAM cap already helps); the reclaimer/OOM walls appear sooner
  on a tight heap, so keep the working set comfortably inside RAM.
- **Graviton / any aarch64 .metal:** once the >=4 GB map fix lands, 10.3 -> 10.1
  knob-set. Per-vCPU behavior should track x86 since the levers are generic.
- **Nested / non-bare-metal (no /dev/kvm):** DO NOT benchmark -- TCG is 10-50x
  slower and meaningless. Bare-metal (or a real nested-KVM host) is mandatory.

## 11. Knobs NOT yet dialed in (honest gaps)

What we have optimized: OSV_WAKE_PULL (high-VU dispersal), the ARC cap + sync
shrinker + retry-reclaim (memory pressure), fd-limit, recordsize/ashift/sync/
logbias, autovacuum-ON survival. What remains UN-tuned or unmeasured:

OSv:
- **OSV_IDLE_SPIN** -- left at the 10000 default; never swept for this workload.
  A longer spin can dodge halt/wake VM-exits at the exit-rate ceiling; worth an
  A/B (`--env=OSV_IDLE_SPIN=100000`) especially under Firecracker.
- **NVMe interrupt coalescing** (OSV_NVME_INT_COALESCING, PR #1481) -- made
  opt-in/off; on instance-store (vwc=0, sync flush free) it was a wash, but on a
  vwc=1 device or a read-heavy sweep it was never re-tuned.
- **Huge pages** -- measured a no-op for this WAL/lock-bound workload (no runtime
  knob; per-VMA >=2MB auto). Not re-examined for a read-heavy or big-
  shared_buffers config where TLB pressure could matter.
- **Page-allocator anti-fragmentation / contiguous-reclaim** -- the extreme-
  scale (>VU192) throughput cliff is fragmentation; no defrag lever exists yet
  (the v26 OOM diagnostic is in place to aim one). Not a crash, so deferred.
- **NUMA** -- the guest is a single NUMA view; cross-socket effects on a 2-socket
  .metal host (memory locality of ARC vs backends) never measured.
- **vCPU pinning / topology** (-smp threads/cores/sockets, host CPU affinity) --
  used defaults; never tuned for cache locality.

Firecracker:
- **vCPU pinning to host cores, and the FC balloon/`--vcpu` sizing** -- not tuned.
- **virtio-MMIO queue depth / IRQ config** -- the FC ceiling at high queue depth
  (~2-3x below QEMU vhost) was observed but not addressed.
- **hugepages/`--huge-pages` on the FC side** -- not tried.

PostgreSQL:
- **wal_buffers, wal_writer_delay, wal_compression** -- not swept; on the wake-
  bound commit path these could change the commit-batch shape.
- **checkpoint_completion_target, bgwriter_lru_maxpages** -- checkpoints were kept
  infrequent for clean A/B; not tuned for steady-state I/O smoothing (matters for
  p99 consistency in production).
- **effective_io_concurrency, max_parallel_workers** -- parallel query / prefetch
  never exercised (TPROC-C is OLTP); relevant for analytics workloads.
- **commit_delay / commit_siblings** -- swept once (null on vwc=0); worth
  revisiting on a vwc=1 device to widen group commit.
- **synchronous_commit=off** -- deliberately kept ON (durability); an off/local
  A/B would quantify the pure-CPU ceiling with the WAL wall removed (a diagnostic
  measurement, not a production recommendation).

Most-consistent-latency (p99) is the least-tuned axis: every result optimized
for throughput (NOPM); p99 was measured but only checkpoint spreading, wake-
locality, and keeping VU near vCPU count were used to steady it. A dedicated
p99-first pass (checkpoint smoothing + wal_writer + bgwriter tuning + a fixed
moderate VU) is the clear next optimization if predictable tail latency under
sustained load is the goal.
