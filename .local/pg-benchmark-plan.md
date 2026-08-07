# PG/OSv vs PG/Linux Benchmark Plan (Milestone 1 parity)

Date: 2026-07-25. Goal: prove STABILITY and PERFORMANCE PARITY-OR-BETTER of
stock PostgreSQL 18 on OSv (KVM + Firecracker) vs on Linux (native), all on
ZFS-on-local-NVMe, huge pages, identical PG + ZFS config.

## METHODOLOGY (authoritative)
- **Workload = HammerDB TPROC-C** (TPC-C-like OLTP). This is THE measure of
  parity. pgbench is only a quick smoke test, not the reported result.
- **Load is generated from SEPARATE EXTERNAL instances** that do NOT host the
  Postgres process. The HammerDB driver(s) run on their own instance(s) and hit
  the DB host over the network, so the driver never steals CPU/RAM/IO from the
  DB under test. The DB host runs ONLY Postgres (+ the OS/hypervisor).
- **Stability first, then performance.** Each config must run a sustained
  HammerDB load (e.g. 30-60 min at the target vuser count) with ZERO errors /
  no crashes / no wedge before its throughput number counts. Report both:
  (a) did it stay up under sustained load, (b) NOPM/TPM + latency.
- Parity target: OSv (KVM and Firecracker) NOPM/TPM within noise of, or better
  than, Linux native, at matched vuser counts, same PG+ZFS config, huge pages.

## Topology (DB host under test + separate load drivers)
- **DB HOST** (m5d.metal, local NVMe): runs ONLY the Postgres-under-test, one
  config at a time. Nothing else competes for its resources.
- **LOAD DRIVER(S)** (separate instance(s), same AZ/subnet for low-latency LAN,
  e.g. c5.4xlarge or c5.9xlarge x1-2): run HammerDB TPROC-C, connect to the DB
  host over the private network (its subnet IP), never share the DB host's CPU.
  Use enough driver capacity that the driver is NOT the bottleneck (scale
  drivers/vusers until the DB host is the limiter).
- Same driver instance(s) + same HammerDB schema/scale drive ALL three DB-host
  configs, so the client side is a constant.

## Three DB-HOST configurations (same host instance, same PG source, same ZFS)
1. **Linux+PG (native control)** — the metal host's own OS (AL2023 or Debian/
   Fedora), PG18 on ZFS-on-NVMe, huge pages, best OS tuning. Baseline (no virt).
2. **OSv+PG under KVM** — the combined OSv image (fork arena + OpenZFS), /data on
   a ZFS pool backed by the local NVMe, huge pages, virtio-blk + virtio-net.
3. **OSv+PG under Firecracker** — the SAME OSv image, Firecracker microVM
   (scripts/firecracker.py), same virtio-blk NVMe-backed drive + tap net.
- Networking: each DB-host config must expose PG on a port the external driver
  reaches (Linux: listen on the private IP; OSv-KVM: tap/bridged NIC on the
  subnet, not user-net hostfwd -- the driver is off-box; OSv-Firecracker: tap on
  the subnet). virtio-net must carry real cross-instance TCP, not loopback.

## THE PREREQUISITE (do first — gating)
fork (integ/pg-fork-arena, HEAD 858dd78f2) and OpenZFS (#1423 pr/openzfs-draft,
HEAD 0f65cdb19) are on SEPARATE branches. The benchmark needs BOTH in one image
(PG forks backends AND /data is on ZFS-on-NVMe). Build a COMBINED branch:
`integ/pg-fork-zfs` = merge pr/openzfs-draft into integ/pg-fork-arena (or rebuild
the merge; there was an earlier integ/pg-fork-zfs). Validate: image builds with
conf_zfs=openzfs + conf_fork=1 + fs=zfs; PG boots, /data on a ZFS pool on the
NVMe device (NOT ramfs), serves concurrent queries. Only then benchmark.

## Storage layout (identical across all 3) — RAID-Z over NVMe + EBS
- Target pool: local NVMe + EBS volumes knitted into a **meaningful RAID-Z**
  configuration (raidz1 or raidz2 across the local NVMe drives + attached EBS
  volumes), so the benchmark exercises a real, durable, redundant ZFS layout
  (not a single disk). Same vdev geometry on Linux and OSv.
  - DB host m5d.metal has 4x 838GB local NVMe (nvme0/1/3/4n1). Attach N EBS
    gp3 volumes (e.g. 4x, matched size/throughput) so the raidz spans both
    NVMe (fast) + EBS (durable/network) tiers. Decide the concrete geometry
    (e.g. raidz1 of {NVMe+EBS} mirrors, or raidz2 across all) so it's
    defensible + identical both sides. NVMe can also serve as L2ARC/SLOG.
  - ZFS tuning identical: recordsize=8k (PG page) or 16k, compression=lz4,
    atime=off, ashift=12, logbias, primarycache; same on Linux and OSv.
  - Linux: zpool create the SAME raidz over the SAME devices, PG datadir on it.
  - OSv: the SAME devices exposed as virtio-blk (one per vdev member) to the
    guest; OpenZFS in-guest builds the SAME raidz pool.
- HUGE PAGES: run every config BOTH ways — once WITH huge pages, once WITHOUT —
  on both Linux and OSv, so the huge-page effect is measured, not assumed.

## PG config (identical, from pg-numa-benchmark guide, scaled to instance)
shared_buffers sized < dataset to be realistic; huge_pages=on both sides;
max_connections, wal_*, checkpoint_* identical. numactl --cpunodebind=0 for the
postmaster on Linux (OSv is single-node in-guest). Same PG 18 source built the
same way (musl PIE for OSv; the guide's stock build for Linux — note: the
BINARY differs (musl vs glibc) but the SQL workload + config are identical; call
this out honestly in results).

## Workloads (HammerDB is the result; pgbench only a smoke)
- **PRIMARY: HammerDB TPROC-C** driven from the external instance(s):
  - Schema build: pg_count_ware (warehouses) sized so the dataset exceeds
    shared_buffers (force real I/O to the ZFS/NVMe), e.g. 500-1000 warehouses.
  - Runs: pg_num_vu (virtual users) swept {8, 16, 32, 64}, each with a rampup +
    a measured interval (e.g. 5 min rampup, 30-60 min measured for the stability
    run; shorter measured intervals for the sweep points).
  - Report NOPM (New Orders Per Minute) + TPM + latency, medians of >=3 runs.
  - One SUSTAINED run per config (>=30-60 min) at the best vuser count purely for
    STABILITY (zero errors, no crash) before the throughput numbers count.
- SMOKE ONLY (not reported as the result): a quick `pgbench -S`/`-c` from the
  driver instance just to confirm connectivity + basic serving before HammerDB.

## Method (apples-to-apples + external-driver discipline)
- DB host runs ONE config at a time; stop/teardown before the next. Nothing but
  Postgres on the DB host.
- Load ALWAYS from the external driver instance(s) over the private network;
  the driver is never on the DB host. Verify the driver isn't the bottleneck
  (driver CPU not saturated; adding a 2nd driver doesn't raise NOPM).
- Same HammerDB version, same schema/scale, same vuser counts across all 3.
- Rebuild/reload the ZFS dataset identically for each config.
- 3 iterations per point, medians + variance; one long stability run per config.
- Record: DB-host instance type, kernel/OSv version, PG version+build flags, ZFS
  version+props, huge pages, full postgresql.conf, driver instance type+count,
  HammerDB config, and raw HammerDB output per run.
- Honesty: OSv-PG = musl PIE with known deviations (WAIT_USE_SELF_PIPE, neutered
  checks, unix_socket_directories=''); Linux-PG = stock glibc. Same SQL + config,
  different libc — state it plainly. The point is TPROC-C throughput/latency
  parity of the same workload under the same external load, and stability.

## Instances
- **DB host**: m5d.metal (x64, KVM, 4x 838GB local NVMe, 377GB RAM, ~$5/hr) —
  the osv-bench instance already launched (i-0cf34f6df400eef9e). Runs the
  Postgres-under-test only. TERMINATE when done.
- **Load driver(s)**: 1-2 separate instances in the SAME subnet
  (subnet-08627f3be3da35553) for low-latency private networking, e.g.
  c5.9xlarge (36 vCPU) — run HammerDB, never host PG. Tag osv-bench-driver.
  Launch when Phase 1 (PG-on-ZFS-on-NVMe) validates. TERMINATE when done.
- SG must allow the driver->DB-host PG port (5432) within the subnet (add an
  intra-SG rule for 5432, or the driver's private IP), plus my SSH to both.

## Deliverable
A results MATRIX: config (Linux / OSv-KVM / OSv-Firecracker) x hugepages{on,off}
x HammerDB vuser count -> NOPM/TPM/latency, medians + variance, driven from the
external instance(s); on the SAME RAID-Z (NVMe+EBS) layout across all; PLUS a
stability verdict per config (survived the sustained run, zero errors) and the
full configs. Honest parity read: is OSv within noise of (or better than) Linux
on TPROC-C? Does OSv-Firecracker == OSv-KVM? What does huge-pages buy each?
Where does OSv win/lose, and is it stable under sustained external load on
durable RAID-Z storage?

## GATING PREREQUISITE (current crux -- must fix before ANY benchmark)
Stock PG reaches "ready" on ZFS-on-NVMe and answers READ queries, but forked
backend WRITES do not round-trip (virtio-blk write counter never moves; the
dirty-list a forked backend appends is not traversed by the AS0 txg_sync). A
write-heavy TPROC-C benchmark is impossible until writes durably commit. Fix
the ZFS dirty-data/txg cross-AS coherence (wall B) + the ZIL lwb sync-write
completion (wall A) until a forked backend INSERT/CHECKPOINT produces real block
I/O and the row survives a clean reboot. THEN build the RAID-Z layout + matrix.

## PHASE 2 (conditional): connection-pooler at extreme client counts
TRIGGER: if the current matrix shows SCALABILITY DROP-OFF at high vuser counts
(NOPM plateauing or declining as vusers climb past ~core count) for EITHER
OSv or Linux -- run a pooled variant to separate "PG process-per-connection
cliff" from "OS/scheduler behavior".

Setup:
- Front the DB host with a connection pooler on the DRIVER side (or a 3rd
  instance): pgbouncer (transaction pooling) first (simplest); optionally also
  pgpool-II or pgcat for cross-check.
- Pooler in TRANSACTION mode, pool_size FIXED so the number of ACTIVE server
  connections = (roughly) the DB host core count -- i.e. active PG processes
  (backends + parallel workers + the fixed aux set) ~= cores. Many HammerDB
  vusers (e.g. 128/256/512) multiplex onto that fixed pool; clients queue at
  the pooler instead of spawning a backend each.
- HammerDB drives a HIGH vuser count (well past cores) through the pooler; the
  pooler holds server-side concurrency at ~core count.
- Run for BOTH Linux and OSv (KVM + Firecracker), hugepages on/off, on the same
  RAID-Z, same external-driver discipline.

What it isolates:
- If pooled OSv and pooled Linux both recover to ~peak NOPM and TRACK each
  other (while unpooled both dropped off), the cliff is PG's process model, not
  OSv -> OSv is at parity for the realistic (pooled) deployment.
- If pooled OSv still diverges from pooled Linux, the delta is OSv's
  scheduler/context-switch/fork behavior under many concurrent backends -> a
  real OSv scalability finding to chase (thread-backed fork + per-child COW
  context-switch cost under load).
- Also report: does OSv's thread-backed-fork model actually make the UNPOOLED
  extreme-count case WORSE or BETTER than Linux's real processes? (OSv backends
  are threads-in-address-spaces; the CR3-switch-on-AS-change cost under heavy
  context switching is the thing to watch -- this is the deepest apples-to-
  apples question about the fork model.)

Deliverable: pooled vs unpooled NOPM at extreme vuser counts, OSv vs Linux,
with the active-PG-process count pinned ~= cores in the pooled runs.

## ZFS recordsize sweep (correctness qualification + benchmark tuning)
Added 2026-07-27. recordsize is a first-class PG-on-ZFS knob, and the current
8k-write-path corruptor is recordsize-SENSITIVE (8k reliably corrupts, 32k masks
it). So recordsize matters twice:

### For QUALIFICATION (correctness) - do NOT let 32k mask the bug
- The corruptor MUST be fixed at DEFAULT recordsize=8k, not merely avoided by
  going to 32k. Qualification battery runs at recordsize=8k + moderate RAM (32G)
  = the regime that currently corrupts. A clean 32k run is NOT qualification.
- AFTER the 8k fix qualifies, ALSO run the qualify battery (pgbench -i -s1000 +
  -c16 -T120 + concurrent catalog reads + fork-churn, reboot-clean) at each of:
  recordsize = 4k, 8k (default/PG-page), 16k, 32k, 64k, 128k -- to confirm the
  fix holds across page sizes SMALLER and LARGER than 8k (a smaller 4k = MORE
  8k-style buffers = more pressure = a good stressor; larger = fewer). Any size
  that still corrupts = an unfixed variant to chase.

### For the BENCHMARK (tuning)
- Add recordsize as a benchmark axis on BOTH OSv and Linux (identical values):
  recordsize = {8k (PG page, the canonical PG-on-ZFS choice), 16k, 32k, 128k}.
  PG page is 8k, so recordsize=8k aligns 1 PG page : 1 ZFS record (best for
  random OLTP writes / avoids read-modify-write); larger recordsize favors
  sequential/bulk + compression ratio but causes RMW on 8k random writes.
- Report the recordsize x {NOPM/tps} curve per config so we can state the
  best-tuned OSv result vs the best-tuned Linux result (apples-to-apples: same
  recordsize compared, AND each side's own best recordsize).
- Keep the other ZFS props fixed (ashift=12, lz4, atime=off, logbias, primarycache)
  while sweeping recordsize, so it's a clean single-variable sweep.

## RECORDSIZE decision (user + corruptor interaction, 2026-07-28)
- PRIMARY = recordsize=8k (matches PG's 8k page; 1:1 alignment, no RMW on random OLTP writes) -- this is THE production-correct config and the headline parity number.
- BUT 8k is exactly where the open corruptor lives (scales w/ 8k-buffer count). So RIGHT NOW: heavy-concurrent-write at 8k corrupts. Approach:
  * Run the benchmark at 8k as the primary AND capture honestly what OSv sustains at 8k (single/light concurrency completes; heavy concurrent write hits the bug -> report as a known-open finding, NOT a masked pass).
  * Use recordsize=32k as the "OSv-qualified-sustained-write" config to get a REAL clean parity A/B now (OSv survives 32k), clearly LABELED "32k; 8k-heavy-write has a known open UAF under fix".
  * Sweep {8k,16k,32k,128k} on BOTH OSv+Linux as a tuning curve (RMW-vs-compression tradeoff) AND to DOCUMENT where the 8k bug bites vs not, on each.
- Once the corruptor is fixed: 8k becomes fully clean -> 8k is the headline parity number. Keep hugepages{on,off} axis throughout.

## TUNED round #2 (after the current untuned baseline completes) — PG-on-ZFS production tuning
Refs: bun.uptrace.dev/postgres/tuning-zfs-aws-ebs, vadosware.io everything-on-optimizing-postgres-on-zfs-on-linux, saurabhnanda gist. The CURRENT run is an UNTUNED baseline (valid apples-to-apples, both sides same generic config: ashift=12, recordsize-sweep, lz4, atime=off, logbias=throughput, primarycache=all, SLOG+L2ARC). Round #2 applies the production tuning IDENTICALLY on OSv + Linux and reports untuned-vs-tuned delta.
ZFS (both sides):
  - recordsize: the guides favor 16k (or 32k) over 8k for PG data even for OLTP (8k = high metadata overhead + poor compression; PG 8k random writes still fine at 16k). Make 16k the tuned-data default; keep the sweep {8,16,32,128k}.
  - SEPARATE WAL dataset: recordsize (8k-16k), possibly logbias=throughput on WAL only.
  - primarycache=metadata on the PG DATA dataset (PG shared_buffers caches data; avoid ARC double-cache) -- but ALSO test primarycache=all (contested); report both.
  - xattr=sa, atime=off, redundant_metadata=most, compression=lz4 (or zstd - test), ashift=12.
  - logbias: test latency vs throughput (default latency often better for PG w/o a dedicated fast SLOG); don't assume throughput.
  - sync=standard + SLOG; consider zfs_txg_timeout tuning.
PostgreSQL (both sides, the big ZFS wins):
  - full_page_writes=off (ZFS CoW is torn-page-safe -> ~halves WAL volume; the #1 PG-on-ZFS win).
  - wal_init_zero=off, wal_recycle=off (CoW makes prealloc/recycle wasteful on ZFS).
  - keep shared_buffers modest (ARC + PG double-cache); the guides suggest smaller shared_buffers on ZFS, larger ARC. Test.
  - checkpoint tuning, effective_io_concurrency for NVMe.
IDENTICAL config both sides (it's a comparison). Report: untuned baseline vs tuned, OSv vs Linux, per recordsize x hugepages. This is the production-relevant "at parity" number.
