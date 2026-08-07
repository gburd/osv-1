# OpenZFS-on-OSv: feature coverage + performance comparison plan

Goal: ensure every OpenZFS feature that BSD-ZFS supported on OSv works on OpenZFS,
document any that don't as explicitly unsupported, and faithfully compare the two
implementations' performance with a focused multi-workload ZFS test (no Postgres /
HammerDB). Executed on EC2 metal (KVM + local NVMe).

## Part 1 - Feature coverage matrix

OpenZFS zfs-2.4.2 exposes 48 pool feature flags plus compression / checksum /
encryption / send-recv / snapshot machinery. BSD-ZFS on OSv shipped a ~2013-era
feature set (async_destroy, empty_bpobj, lz4, a handful more). "Match BSD or mark
unsupported" means: for each capability, confirm it works on OpenZFS-on-OSv; if a
BSD-supported capability regresses on OpenZFS, that is a bug to fix; OpenZFS-only
capabilities that don't work get listed UNSUPPORTED (they were never a BSD promise).

Test tiers (each = a scripted `zpool`/`zfs` sequence run inside OSv, asserting exit
status + expected `zpool get`/`zfs get`/`zdb` state, on a pool backed by the local
NVMe via virtio-blk):

### Tier 0 - core (must work; BSD did these)
- pool: create (single vdev), import/export, `zpool status`, scrub, `zdb -C`
- dataset: create/destroy, mount/unmount, mountpoint, nested datasets
- I/O: write/read/sync a file, verify checksum integrity after scrub
- properties: recordsize, atime/relatime, canmount, readonly
- compression: off, lz4  (BSD had lz4)
- checksum: fletcher4 (default), sha256

### Tier 1 - vdev topologies
- mirror (2-way), raidz1 (3 dev), raidz2 (5 dev), raidz3 (7 dev)  <- the 7-file layout maps here
- resilver: offline a device, replace, confirm resilver completes + data intact
- SLOG (separate log device) + L2ARC (cache device)
- scrub finds + repairs an injected error (zinject) on redundant vdev

### Tier 2 - snapshots / clones / send-recv
- snapshot create/list/rollback/destroy
- clone from snapshot, promote
- `zfs send` | `zfs recv` (full + incremental) between two datasets/pools
- bookmarks (com.delphix:bookmarks)

### Tier 3 - OpenZFS-only capabilities (MAKE THEM WORK; unsupported only as last resort)

Directive: Tier 3 features must be made to work properly on OSv.  If one FAILs,
diagnose + FIX it (OSv source or a new patch in modules/open_zfs/patches/).  Only
after a genuine fix attempt that proves it cannot reasonably work on OSv (e.g. needs
a Linux/FreeBSD kernel facility OSv fundamentally lacks) does it get documented as
unsupported, WITH the specific reason it can't work.

- compression: gzip-{1,9}, zstd-{1,3,19}, zle, lzjb
- checksum: sha512, skein, edonr, blake3
- encryption (com.datto:encryption): create encrypted dataset, load/unload key, r/w
- dedup (+ fast_dedup)  <- memory-heavy; run at small scale
- block cloning (com.fudosecurity:block_cloning) - reflink/copy_file_range
- large_dnode, large_blocks (recordsize 1M+), longname
- draid, raidz_expansion, device_removal
- TRIM (autotrim + manual `zpool trim`) - ties to OSv's block TRIM (PR #1400 merged)
- checkpoint (zpool_checkpoint)

Output: a matrix table  [capability | BSD-on-OSv | OpenZFS-on-OSv | notes], each cell
PASS / FAIL / N/A. Anything FAIL on OpenZFS that was PASS on BSD = a fix target
before merge.  OpenZFS-only (Tier 3) FAILs are ALSO fix targets - fix first;
document "unsupported on OSv" only after a real fix attempt fails, with the reason.

## Part 2 - Performance comparison (focused ZFS microbench, no DB)

Reuse where possible: tests/misc-zfs-io.cc, tests/misc-zfs-db-sim (from
integ/postgres-raidz's device-backed db-sim + SLOG work). Otherwise a small fio-style
driver inside OSv. Same OSv image commit, only `conf_zfs=bsd|openzfs` + matched zfs
props differ. Pool = raidz2 over 7x250GB files on local NVMe (as specified), plus a
single-vdev variant to separate raidz overhead from impl difference.

Workloads (each: warmup discarded, >=3 reps, report median + stdev/CI; steady-state
>= 60s per rep for micro, the 15-min steady-state reserved only if variance demands):
1. seq write (1M blocks, compression=off)         -> MB/s        [DMU/vdev write path]
2. seq read, cold cache (drop ARC)                -> MB/s        [vdev read path]
3. seq read, warm cache (working set < ARC)       -> MB/s        [ARC hit path - impl diff]
4. random 4K read, QD 1/8/32                       -> IOPS, p99   [ARC + indirect blocks]
5. random 4K write, QD 8                           -> IOPS, p99   [RMW, txg]
6. mmap sequential read (2G, WS<ARC then WS>>ARC) -> MB/s + RSS   [THE zero-copy/ARC-bridge measure]
7. fsync-heavy append (ZIL)                        -> fsync/s     [ZIL/SLOG path]
8. metadata: create/stat/unlink 100k small files  -> ops/s
9. compression effective throughput lz4 on/off     -> MB/s + ratio [OpenZFS vs BSD lz4]
10. scrub throughput on a full pool                -> MB/s
11. O_DIRECT seq write + read (PAGE_SIZE-aligned)  -> MB/s        [OpenZFS-only: bypasses
    OSv page cache AND ARC entirely - pure DMU/vdev path, no OSv-cache layer.  Set
    `zfs set direct=always` (or O_DIRECT open).  Compare vs workload 1/2 (cached):
    quantifies what OSv page cache + ARC add/cost.  Confirm via arcstats these I/Os
    don't populate ARC.  BSD-ZFS has no direct path, so report: OpenZFS-O_DIRECT vs
    OpenZFS-cached vs BSD-cached vs raw-NVMe ceiling.]

Baselines/ceilings: raw NVMe fio on the host (the "no-cap" ceiling), and same
workload on Linux-ZFS-on-metal as a reference upper bound for OpenZFS.

Success framing (user's): ideally OpenZFS >= BSD on every workload; where BSD wins,
the difference must be explainable + reasonable (e.g. OpenZFS's richer checksum/ARC
bookkeeping, the borrow-vs-full-bridge gap on workload 6, scatter-ABD copy on mmap).
Workload 6 specifically quantifies the ARC-bridge follow-up from the PR discussion.

## Execution notes
- Metal only (KVM). TCG numbers are meaningless for I/O - reject any run not on KVM.
- OpenZFS needs the runtime abort fixed first (separate task, in flight). Feature +
  perf tiers are gated on "OpenZFS mounts a pool + does GB/s-class I/O".
- Instance: m5d.metal suffices for feature tiers (3.6TB NVMe > 1.75TB). i3en/i4i.metal
  for the perf raidz2-over-7x250G run if seq throughput needs more NVMe bandwidth.
- Feature scripts live in a new modules/zfs-feature-test/ (impl-agnostic; same script
  run under conf_zfs=bsd and conf_zfs=openzfs). Perf harness extends misc-zfs-io.
- Result goes into the PR as a coverage matrix + a perf table.
