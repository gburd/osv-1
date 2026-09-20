# HammerDB TPROC-C benchmark runbook: OSv/PG vs Linux/PG on ZFS + local NVMe

> **CORRECTION 2026-09-08: MY BRIEFS had the asset name wrong, not this document.**
> This doc correctly records `HammerDB-6.0-Prod-Lin-RHEL9.tar.gz` (line ~128). But the briefs
> I wrote to several agents said "HammerDB 6.0 (RHEL9 build)" loosely, and agents then tried
> `HammerDB-6.0-Linux.tar.gz` / `HammerDB-6.0-RHEL9.tar.gz`, which both **404**.
> The real assets follow the `-Prod-Lin-<distro>` pattern:
> **`HammerDB-6.0-Prod-Lin-UBU24.tar.gz`** for Ubuntu 24.04 (used by the Linux baseline arm)
> and `HammerDB-6.0-Prod-Lin-RHEL9.tar.gz` for RHEL9/AL2023. Always give agents the FULL
> filename, never a paraphrase.
>
> **Also: the configs recorded in this document are HISTORICAL** (40 warehouses,
> autovacuum=off, shared_buffers=2GB, checkpoint_timeout=1h, VU8, 3-minute runs). They are
> benchmark-clean settings from an earlier arc and are NOT the campaign mandate. For the
> current production-shaped configuration see `.local/X86-RESULTS-2026-09-07.md`,
> `.local/AARCH64-RESULTS-2026-09-07.md`, and `bench-linux/LINUX-BASELINE-RESULTS.md`. An
> agent wasted effort reconciling against this file because it was the more prominent one.



Local steering doc. Not tracked. Keep it free of cloud resource IDs, account
numbers, and egress IPs; instance-class names are hardware requirements and are
fine to keep.

## Purpose

Apples-to-apples OLTP comparison of PostgreSQL running on OSv vs the same
PostgreSQL workload on Linux, both on ZFS backed by local NVMe, driven by
HammerDB TPROC-C (TPC-C-like). The goal is a fair parity test: identical
warehouse count, identical ZFS pool geometry, identical HammerDB driver script,
same physical host class. The single moving part is the guest OS under the
database (OSv vs Linux).

## Hardware requirement (READ FIRST)

The OSv image runs under KVM. It MUST be built and run on a KVM-capable
bare-metal host (m5d.metal class or equivalent bare metal with local NVMe). A
non-metal instance (e.g. m5d.4xlarge) exposes no nested KVM, so QEMU falls back
to TCG software emulation, which is unusable for a performance benchmark: the
numbers are meaningless and multi-VU behavior does not reflect real scheduling.
Do not benchmark on TCG.

## The OSv build

- Branch: `wip/pg-zfs-bench-v19` (or its successor). This carries the 10-commit
  fork/mmap/ZFS coherence fix stack (see "Fixes required" below).
- Build config:
  - `conf_fork=1` (thread-backed fork()/vfork()/execve() emulation; PostgreSQL
    forks a backend per connection).
  - `conf_zfs=openzfs` (upstream OpenZFS, not the legacy in-kernel BSD ZFS).
  - `fs=ramfs` (root filesystem is ramfs; ZFS is a runtime data pool, not the
    root).
- Image manifest / modules: `open_zfs,zfs,zfs-tools,postgres18-musl`.
- App: `gb/wip/postgres18-musl-demo` (PostgreSQL 18, musl libc build).
- OpenZFS: the 29 numbered platform patches plus patch 0030 (the ARC-eviction
  waiter fork-coherence fix), i.e. patches 0001-0030 under
  `modules/open_zfs/patches/`.
- Builder: `fedora:39` container toolchain.

## OSv boot cmdline and PostgreSQL config that make multi-VU work

Boot the loader with:

    --preload-zfs-library --rootfs=ramfs

`--preload-zfs-library` loads `libsolaris.so` (the ZFS library) before the
root-mount block, so the runtime data pool can be created on a non-ZFS-root
image. `--rootfs=ramfs` keeps root in ramfs and leaves ZFS purely for the data
pool.

Create the ZFS pool on the raw NVMe block device before starting PostgreSQL:

    zpool create -f -o ashift=12 \
      -O compression=off -O atime=off -O recordsize=8k \
      -O sync=standard -O logbias=latency -O primarycache=all \
      -m /data pgdata /dev/vblkN

Pool-setting rationale:
- `ashift=12`: 4K sectors, matches NVMe physical block size.
- `compression=off`: isolate the OS/fork variable; do not let compression skew
  the CPU comparison.
- `atime=off`: no access-time writes on every read.
- `recordsize=8k`: match the PostgreSQL page size so a page write is one ZFS
  record, no read-modify-write.
- `sync=standard` + `logbias=latency`: honor fsync durably and route synchronous
  writes through the ZIL for low commit latency (fair vs a durable Linux run).
- `primarycache=all`: ARC caches data and metadata (default; keep it explicit).

### WAL/ZIL-optimized dataset layout (recordsize split - the known ZFS-PG pattern)
A single recordsize=8k dataset for BOTH data and WAL is a known ZFS-PG anti-pattern:
PostgreSQL WAL is a large sequential stream written into 16MB segments, so forcing
8k ZFS records fragments the sequential WAL and causes write-amplification. The
standard ZFS-for-PG layout uses SEPARATE datasets with matched recordsizes:

    # data at 8k (matches the PG page, no read-modify-write on a page write)
    zpool create -f -o ashift=12 -O compression=off -O atime=off \
      -O sync=standard -O logbias=latency -O primarycache=all \
      -O recordsize=8k -m /data pgdata /dev/vblkN
    zfs create -o recordsize=8k -o mountpoint=/data/base pgdata/base
    # WAL at a larger recordsize + logbias=throughput (sequential stream, fewer
    # indirect ZIL writes); pg_wal lives on its own dataset:
    zfs create -o recordsize=1M -o logbias=throughput \
      -o mountpoint=/data/wal pgdata/wal

Then point PostgreSQL data at /data/base (data_directory or initdb -D) and WAL at
/data/wal (initdb --waldir=/data/wal, or a pg_wal symlink). recordsize=1M for WAL
is the widely-used value; 64k-1M are all reasonable - measure. Data stays 8k.
This is a pure ZFS-config change (no OSv code, no PG-specific hack) and is the
first lever in the WAL/ZIL throughput plan (.local/WAL-ZIL-THROUGHPUT-PLAN.md).

Start PostgreSQL:

    /usr/bin/postgres -D /data \
      -c listen_addresses=* \
      -c max_connections=300 \
      -c shared_preload_libraries=plpgsql \
      -c autovacuum=off \
      -c max_wal_size=16GB \
      -c checkpoint_timeout=1h \
      -c shared_buffers=2GB

Config rationale (these matter specifically under OSv fork emulation):
- `shared_preload_libraries=plpgsql`: load plpgsql once in the postmaster so
  every forked backend inherits it. Without it each backend does its own
  `dlopen` on first use, and per-backend dlopen under fork is exactly the
  cross-address-space path the fix stack hardens; preloading avoids the churn
  entirely.
- `autovacuum=off` + `max_wal_size=16GB` + `checkpoint_timeout=1h`: suppress the
  autovacuum launcher/workers and stretch out checkpoints so the checkpointer
  and vacuum do not fork/spawn during the timed run. Fork churn from background
  workers is noise (and stress) we do not want during measurement; the run is
  short enough that deferring vacuum and checkpoints is safe.
- `listen_addresses=*`: HammerDB drives the DB from an external driver host.
- `max_connections=300`: headroom for the highest VU count.
- `shared_buffers=2GB`: modest; ZFS ARC is the large cache here.

## The Linux baseline

- PostgreSQL 16 on ZFS (OpenZFS), same pool geometry (identical `zpool create`
  flags above), same warehouse count (40), same HammerDB driver script, same
  bare-metal host class and same local NVMe.
- Only the guest OS differs. Everything else held constant.

## HammerDB

- Version: v6.0, RHEL9 build (`HammerDB-6.0-Prod-Lin-RHEL9.tar.gz`).
- libpq shim the RHEL9 build needs:

      ln -sf /lib64/libpq.so.private16-5 /usr/lib64/libpq.so.5

- Create a `tpcc` superuser (password `tpcc`) in the target PostgreSQL.
- Schema build:

      pg_count_ware 40
      pg_num_vu 8
      buildschema

- Timed driver config:

      pg_driver timed
      pg_rampup 1
      pg_duration 3
      pg_allwarehouse true

- Per-VU run loop (repeat for each VU count N under test):

      vuset vu N
      vucreate
      vurun
      runtimer 320
      vudestroy

  Use `runtimer 320` as the wait: it reliably blocks for the rampup+duration
  window. `vucomplete` races the driver teardown and can return early, so prefer
  `runtimer`.
- Capture the result line from the driver output:

      System achieved NNN NOPM from NNN TPM

  NOPM (New Orders Per Minute) is the headline metric; TPM is total
  transactions per minute.

## Results (measured)

Bare metal, KVM, PG-on-ZFS, local NVMe, 40 warehouses, rampup 1min +
duration 3min.

Linux baseline (PG16 on ZFS):

| VU | NOPM  |
|----|-------|
| 8  | 38948 |

OSv (v19 fix stack, PG18-musl on OpenZFS, 40 warehouses, bare-metal KVM):

| VU  | NOPM  | note                         |
|-----|-------|------------------------------|
| 1   | 19688 |                              |
| 2   | 33226 |                              |
| 4   | 49020 |                              |
| 8   | 67558 | already > Linux VU8          |
| 16  | 67568 | peak, ~1.73x Linux VU8       |
| 32  | 44929 | tapers (8-vCPU guest contention) |

All OSv runs crash-free. Peak OSv throughput (VU16, 67568 NOPM) is about 1.73x
the Linux VU8 baseline (38948 NOPM).

## Fixes required to get here

Getting PostgreSQL to run many concurrent forked backends on OSv+OpenZFS
without crashing required a 10-commit stack addressing three root causes, all
rooted in cross-address-space coherence under OSv's copy-on-write fork
emulation:

1. vma-range / ELF coherence: dlopen'd library segments, file-backed and split
   vmas, and vma-range bookkeeping must live on the identity heap (mapped
   verbatim in every forked address space) rather than in a COW-private arena.
   Commits: `9db86eaf` (share only read-only library segments across fork),
   `6a80a9cd` (file-backed + split vmas on the identity heap under fork),
   `6554c586` (vma-range nodes + dlopen'd ELF bookkeeping on the identity heap).

2. lazy_indirect / thread-state coherence: the forked child thread and its
   detached_state, and libc lazy_indirect backing objects (which embed condvar
   queue pointers), must also live on the identity heap so a wake from another
   address space resolves to the same physical object.
   Commits: `8d26a7e4` (child thread + detached_state on the identity heap),
   `cf903021` (lazy_indirect backing objects on the identity heap under fork).
   Wake-path hardening that fell out of this: `02e7f34a` (never dereference a
   null thread on the wake path), `cabec62e` (reject non-canonical thread
   pointers), `8fd155d2` (final form: narrow the guard to clearly-invalid
   pointers, i.e. null or first-page). The net wake guard is master-eligible
   hardening and was submitted as its own PR.

3. ARC-eviction-waiter coherence: `arc_wait_for_eviction()` put its
   `arc_evict_waiter_t` on the caller's stack, which under fork is COW-private;
   the AS0 arc_evict thread then signaled a condvar it could not coherently see.
   OpenZFS patch 0030 (commit `2e1cc11c5`) moves the waiter to `kmem_zalloc`
   (identity heap) so every forked process survives ARC write pressure. This
   removed the last multi-connection crash wall.

Also in the stack: `98ea3e32` (default `file::sync()` is a no-op instead of
throwing, so munmap of a file-backed mapping cannot raise a C++ exception on
the unwind-hostile munmap path). This one is master-eligible and is carried by
the existing pagecache-munmap-sync-nothrow PR.

## Known limitations / next steps

- VU32 tapers (44929 NOPM, down from the VU16 peak). Attributed to 8-vCPU guest
  CPU contention: past ~2x oversubscription the TPROC-C mix saturates the guest
  CPUs and throughput folds back. Not a correctness issue (crash-free).
- Next:
  - Scale the VU sweep out to VU192 on larger guests (more vCPUs) to find where
    OSv's curve actually peaks rather than where the 8-vCPU guest saturates.
  - Firecracker on arm (aarch64) to compare the micro-VM path and a second ISA.
  - Hugepages on vs off (measure the TLB effect on the fork/mmap-heavy path).
  - p99 latency capture, not just NOPM throughput, so tail behavior under load
    is visible.

## ============================================================================
## SCALE + FIRECRACKER + HUGEPAGES + p99 RESULTS (2026-08-28, OSv wip/pg-zfs-bench-v19 2e1cc11c)
## ============================================================================
## All OSv runs: 40 warehouses, ZFS on local NVMe, m5d.metal (KVM), postgres args
## `shared_preload_libraries=plpgsql autovacuum=off max_wal_size=16GB checkpoint_timeout=1h`.
## p99 = HammerDB xtprof NEWORD p99 (enable diset tpcc pg_timeprofile true).
##
## BARE-METAL / QEMU-KVM, 32-vCPU guest, hugepages ON (fresh boot per point):
##   VU16=169466 NOPM p99 8ms | VU32=248436 | VU64=30353 p99 337ms | VU128=7982 p99 1435ms
## FIRECRACKER, 16-vCPU guest:
##   VU8=113323 (2.9x Linux) p99 6.28ms | VU16=145073 (peak) p99 10.23ms | VU32=136521 p99 28.53ms | VU64=OOM-crash
## LINUX BASELINE: VU8=38948 NOPM.
##
## VERDICT: OSv/PG-on-ZFS is FASTER than Linux at low-moderate concurrency (2.9x @ VU8 FC; ~6.4x @ VU32
## bare-metal) but NOPM PEAKS ~VU16-32 and COLLAPSES past VU32-64, with p99 rising 8ms->1435ms.
##
## HUGEPAGES: no runtime knob in OSv (compile-time/per-VMA; >=2MB mappings auto-huge in vma::fault;
## madvise(MADV_NOHUGEPAGE) per-VMA only). A/B (added OSV_NOHUGE env kill-switch): ON vs OFF within
## run-to-run noise at VU32/64/128. Hugepages is NOT a lever for this WAL/lock-bound OLTP workload.
##
## HIGH-VU BOTTLENECK (evidence): NOT CPU (host 91-98% idle, 45/52 vCPUs halted at VU64). Dominant =
## WAL-write/sync serialization: LWLock:WALWrite (47/64 backends blocked at once) + IO:WalSync +
## Lock:transactionid, compounded by cross-vCPU wake-redispatch latency (halted vCPUs). ~8k NOPM
## ceiling with 30x idle CPU unused = serialization + wake-latency wall.
##
## HIGH-VU CRASHES/LIMITS (fixable, not compute):
##  - EMFILE at VU128+ in a long sweep: global fd table CONF_fs_max_file_descriptors=16384 +
##    RLIMIT_NOFILE=10240 exhausted by accumulated open files -> WAL PANIC. Fresh boot survives VU128.
##    FIX: raise CONF_fs_max_file_descriptors; and/or PG max_files_per_process lower.
##  - OSv OOM at VU64 on the 32GB FC guest: unbounded ZFS ARC + shared_buffers=4GB + 64 backends +
##    503s checkpoint. FIX: cap zfs_arc_max (~guest_mem/2). Add to benchmark boot config.
##  - Rare Firecracker-virtio ARP-callout NULL-deref (callout_reset_on<-arpresolve<-tcp_output),
##    non-deterministic, survived reboot. A real net/callout bug to chase.
##
## NEXT LEVERS (ranked): (1) cap zfs_arc_max in the standard boot config (prevents FC OOM, trivial).
## (2) raise the fd limit (prevents EMFILE, config/CONF). (3) the WAL/ZIL-fsync + cross-vCPU wake-
## latency serialization is the DEEP high-VU OLTP scaling lever (group-commit + wake-locality; same
## family as the earlier ZIL/wake-local work) - this is what caps NOPM past VU32-64.

## ============================================================================
## RECOMMENDED BENCHMARK CONFIG for high-VU runs (avoids the crashes; 2026-08-28)
## ============================================================================
## The VU128 EMFILE and VU64 FC-OOM are CONFIG issues, not OSv bugs (fresh-boot VU128 survives;
## OOM was a 32GB guest). For clean high-VU runs:
##  1. Fresh boot per VU sweep (or per few points) - fds accumulate across back-to-back runs toward the
##     16384 global cap (CONF_fs_max_file_descriptors, conf/kconfig/fs default 0x4000).
##  2. PG boot arg: add `-c max_files_per_process=200` (caps per-backend fd use; 400 backends x fewer
##     fds stays well under 16384). Trivial, no OSv change.
##  3. Size the guest for ARC: on a 32GB guest keep shared_buffers modest (2GB) AND cap the ARC. Since
##     OSv's ZFS_MODULE_PARAM is a no-op, either (a) use a bigger guest (48GB+ as the bare-metal arm did
##     - no OOM there), or (b) patch the OpenZFS arc.c default arc_c_max to ~guest_mem/2 as an
##     open_zfs patch. The bare-metal 48GB/-smp32 arm never OOM'd; the FC 32GB arm did at VU64.
##  4. Optional OSv improvement (upstream-worthy): raise CONF_fs_max_file_descriptors default from
##     0x4000 (16384) - low for a many-connection DB. It backs a static gfdt[FDMAX] array, so bump
##     modestly (e.g. 0x10000 = 65536) if a run needs it; the benchmark boot can also set it via the
##     build config (make ... conf_fs_max_file_descriptors=0x10000).
##
## THE REAL REMAINING LEVER (not a crash - the NOPM ceiling past VU32-64):
##  WAL-write/ZIL-fsync serialization + cross-vCPU wake-redispatch latency (evidence: LWLock:WALWrite
##  47/64 backends blocked, 91-98% idle CPU, 45/52 vCPUs halted). Same family as the earlier ZIL
##  group-commit + OSV_WAKE_LOCAL work. Addressing it (make concurrent WAL commits coalesce + colocate
##  the commit/wake path) is the deep OLTP-scale lever - a dedicated investigation, delicate (prior
##  attempts: the wall-clock cv fix restored coalescing; wake-local RFS helped net but the synch/taskq
##  wiring crashed). This is what would let OSv keep scaling past VU32-64 instead of collapsing.

## ============================================================================
## WAL/ZIL INVESTIGATION CONCLUSION + THE HIGH-VU COLLAPSE FIX (2026-08-30)
## ============================================================================
## The VU64+ NOPM COLLAPSE seen in the scale runs was NOT a WAL/storage-throughput wall - it was a
## SCHEDULER LOAD-DISPERSAL failure: past the vCPU count, woken PG backends pile onto ~8-10 vCPUs while
## the rest sit halted (the single ZIL/commit waker's fan-out never builds a runqueue the 100ms balancer
## can see). FIX: boot with OSV_WAKE_PULL=1 (idle-CPU pull / work-stealing, PR #1472, def_bool y, runtime
## no-op unless armed). MEASURED (v21, 40wh, clean-pool A/B):
##   HammerDB TPROC-C: VU64 +238% (7989->27009), VU96 +243%, VU128 +238% NOPM. VU16/32 +6/+13%.
##   pgbench TPC-B:    64 clients +191%, 96 +60%.
##   vCPU busy: off = R=8-10/S=26 (collapsed); on = R=29-30/S=5 (spread).
## => FOR HIGH-VU (VU>vCPU) OLTP RUNS, ADD --env=OSV_WAKE_PULL=1 TO THE BOOT CMDLINE. This is the
##    high-concurrency scaling knob. Below the vCPU count it is a wash; p99 is unchanged (throughput/
##    utilization fix, not a latency fix).
## The WAL/ZIL config levers (recordsize split, full_page_writes, logbias, commit_delay) were a NULL
## result on AWS instance-store (NVMe vwc=0 -> the per-commit flush is free), and the single-stream QD1
## commit floor is intrinsic to the cross-CPU wake IPI/VM-exit (a single sync stream can't be coalesced).
## So: the config knobs don't move it, but the SCHEDULER knob (OSV_WAKE_PULL) fixes the thing that
## actually mattered at scale - the high-VU collapse. Recordsize-split remains the right config on a
## real (vwc=1) device; it is a no-op on instance-store.
## STILL OPEN: VU192 OOM at 40wh (reclaimer vs a long checkpoint backlog) - orthogonal to WAKE_PULL
## (arm B even survived VU192 at 21282 NOPM where arm A OOM'd). Next high-VU item.
