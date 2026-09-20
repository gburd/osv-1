# HammerDB scaling re-test with the footprint fix (#3) + the VU32 distinct factor (#4)

**Run date:** 2026-09-20. **Base:** `gh-fork/bank/fork-footprint-reduction-signed` @ `1480fbee1`
(exact SHA verified on-box; all 5 commits verify `%G?==G` locally, signer greg@burd.me),
apps `3f93f43` (`mkdir(dst, 0700)` gate == 1). `bench-base-gate.sh`: **PASS**, all 9 markers.

**Boxes (Owner=agent-scale, hotdog 585335547908, us-east-2a) — TERMINATED at end:**
- METAL `i-00b52ea02ffc05430` m5d.metal (Debian 12) — both guests + host instrumentation
- DRV `i-0295dadedf57f4f0c` c5.9xlarge (Ubuntu, 36 vCPU) — HammerDB 6.0 driver

---

## THE TABLE — matched OSv vs Linux, equal cache, one m5d.metal, fresh boot per cell

Medians of VALID reps. All NOPM are MEASURED HammerDB output. `r1 KEPT` (never voided as cold).

| VU | OSv reps (NOPM) | OSv med | Linux reps (NOPM) | Linux med | **OSv/Linux** | OSv wedged | OSv p99 (ms) | Linux p99 (ms) | OSv per-backend MB | OSv qemu-cpu | Linux qemu-cpu | OSv nvme %util | Linux nvme %util | driver |
|----|-----------------|---------|-------------------|-----------|---------------|------------|--------------|----------------|--------------------|--------------|----------------|----------------|------------------|--------|
| 32  | 142163, 160891 | **151,527** | 290379, 280077 | **285,228** | **0.53** | 0/2 | 32.5 | 12.1-13.0 | **9.6** (42 AS) | 1688 (53%) | 1972 (62%) | 53.0 | 36.7 | OK |
| 64  | 173107, 166217, 157537 | **166,217** | 465493, 284552, 237345 | **284,552** | **0.58** | 0/3 | 26.2-61.9 | 15.6-41.0 | **10.1** (74 AS) | 1733 (54%) | 2675 (**84%**) | **95.1** | 44.8 | OK |
| 128 | 176798, 129799 | **153,299** | 507274, 216230 | **361,752** | **0.42** | **1/3** | n/a¹ | 30.9-112.5 | **12.0** (138 AS) | 1887 (59%) | 2761 (**86%**) | **96.7** | 44.7 | OK |
| 192 | 149905 | **149,905** | 489663, 194160, 204343 | **204,343** | **0.73** | **2/3** | n/a¹ | 43.4-256.4 | **12.5** (202 AS) | 1851 (58%) | 2811 (**88%**) | **94.9** | 39.0 | OK |

¹ HammerDB 6.0's xtprofile gather produced no NEWORD p99 for these cells (known artifact); NOPM
and all host-side numbers unaffected.

**DRIVER VALIDITY — every cell is DRIVER_OK.** Driver all-CPU 0-9% of 36 vCPU, NIC 5-27 Mbps
against ~10 Gbps, at VU192 as much as at VU32. No cell is driver-limited; none is invalidated on
that ground. The ratio also **diverges** with VU (0.53 → 0.58 → 0.42 → 0.73 with Linux's own
variance) rather than converging to 1.0, and the wall appears in **one arm only** — both are the
opposite of the client-side-limit signature.

---

## #3 SCALING — two separate answers: the fix WORKS; OSv still does NOT scale like Linux

### (a) The footprint fix is VALIDATED end-to-end under real load. This is unambiguous.
| VU | live AS | per-backend MB | ovf committed | ovf **recycled** | ovf live | memfree min→last | OOM | EMFILE | abort |
|----|---------|----------------|---------------|------------------|----------|------------------|-----|--------|-------|
| 32  | 42  | **10.0** | 2,462 MB | 15,559 MB | 32 MB | 14.1 → 36.3 GB | 0 | 0 | 0 |
| 64  | 74  | **10.5** | 2,830 MB | **509,772 MB** | 47 MB | 13.8 → 24.0 GB | 0 | 0 | 0 |
| 128 | 138 | **12.2** | 3,507 MB | **1,387,900 MB** | 626 MB | 12.9 → 36.2 GB | 0 | 0 | 0 |
| 192 | 202 | **12.5** | 4,138 MB | **1,461,044 MB** | 1,659 MB | 12.3 → 26.0 GB | 0 | 0 | 0 |

- **Per-backend private memory is 9.4-12.5 MB and FLAT from 42 to 202 backends** — the predicted
  ~10MB/backend, now confirmed under HammerDB load rather than in a probe harness. At the old
  ~247MB/backend, 202 backends would need ~50GB; this run used ~2.5GB.
- **74 backends is the exact count that OOM-wedged before the fix; it now completes** (VU64
  173,107 NOPM, 3/3 reps, zero OOM). **202 backends complete at VU192.** The VU64 OOM wall is GONE.
- Recycling is demonstrably the mechanism: VU192 served **1.43 TB** of cumulative overflow churn
  out of 1.66 GB live (≈880:1). Zero `ovfforeign` frees — the C2-safety property held.
- **No regression of anything previously fixed**: zero OOM, zero EMFILE, zero abort/panic in
  every cell; memfree RECOVERS rather than declining monotonically (so leak #2 and the footprint
  regression are both absent); no VU32 dentry wedge (#1502 holds end-to-end).

### (b) The scaling verdict: **NO — OSv does not scale like Linux on this workload.**
OSv is flat-to-declining across the whole range: median 151.5k → 166.2k → 153.3k → 149.9k. It
gains 10% from VU32 to VU64 and then goes nowhere. Linux is higher at every VU (285k → 285k →
362k → 204k; it too degrades at VU192, but from a much higher level). OSv trails at **every**
concurrency, by 0.42-0.73x, and **wedges outright in 3 of 11 high-VU cells** (VU128 1/3, VU192 2/3).

The footprint fix did exactly what it was for — it removed the memory wall — but what it revealed
underneath is a throughput/liveness ceiling, not Linux-like scaling. Both must be reported.

### The mechanism, from the instrumentation (it is NOT memory)
At VU64-192 **OSv's NVMe sits at 95-97% utilization while Linux's sits at 39-45%** — on
fio-verified-equivalent devices (0.4% apart), identical ZFS geometry, identical io_uring, while
doing ~half to a third of the transactions. Simultaneously **OSv's CPU never saturates (53-59%)
while Linux's does (84-88%)**. OSv is device/IO-path-saturated and CPU-idle; Linux is CPU-bound
with device headroom. OSv is issuing far more device work per transaction, or retiring it far
less efficiently — the same conclusion #4 reaches by an independent route.

---

## #4 THE VU32 FACTOR — ANSWERED: it is **NOT** the ZIL/WAL commit path

| cell | NOPM | qemu-cpu /3200 | nvme %util | dominant waits |
|---|---|---|---|---|
| OSv VU32 durable | 142,163 | 1739 (54%) | 36.8 | LWLock/WALWrite 22.6%, **LWLock/AioUringCompletion 12.3%** |
| Linux VU32 durable | 290,379 | 1714 (54%) | 28.4 | LWLock/WALWrite 51.1% |
| OSv VU32 **nondurable** | **37,751** | **190 (6%)** | 0.44 | IO/DataFileWrite 50.7%, **LWLock/AioUringCompletion 22.9%** |
| Linux VU32 **nondurable** | **600,174** | **2727 (85%)** | 36.9 | NONE/NULL 66.2% (CPU-bound) |

Durability removed identically on both arms (`fsync=off` + `synchronous_commit=off`, verified via
`pg_settings`). The gap did **not** vanish — it **widened**, 0.49x → 0.063x.

- **Linux behaves textbook**: freed from per-commit fsync it becomes CPU-saturated (85%) and
  throughput DOUBLES (290k → 600k). Durability was its limiter.
- **OSv COLLAPSES**: 142k → 37.7k with qemu-cpu at **190/3200 = 6% of ONE core across 32 vCPU**
  and nvme %util 0.44. Neither CPU-bound nor IO-bound: **WAITING.**

### VERDICT: **WAITING, not CPU-saturated. The factor is OSv's ASYNCHRONOUS WRITE-COMPLETION path (io_uring completion / ZFS-pagecache writeback) — not the commit path, not memory, not cache size.**
By the brief's own rule, a gap that persists without durable writes rules out the ZIL/commit
explanation (the prior "OSv ~1.5 vs Linux ~13 lwbs in flight" suspect). The qemu-cpu number then
settles the second split: OSv never approaches CPU saturation in either mode, so this is not a
cycles-per-transaction/path-length cost (B1) — it is a **latency/blocking cost (B2)**.

**`LWLock/AioUringCompletion` is the OSv-specific fingerprint**: top-3 wait in BOTH OSv cells
(12.3% durable, 22.9% nondurable), present in NEITHER Linux cell. With `fsync=on`, WAL commit
serialization partially MASKS it; remove that serialization and it becomes the entire story. And
in the wedged cells it reaches **99.2-99.5%** of all sampled waits with the device completely idle.

**#3 and #4 converge on ONE factor, not two.** The same completion-path deficit that costs ~2x at
VU32 saturates the device at VU64-192, and at VU128/192 escalates from a slowdown into a hang.

---

## The wedge: a NEW bug, cleanly separated from the footprint fix (3 occurrences)
| cell | qemu-cpu | nvme %util | live AS | per-backend MB | memfree | OOM/EMFILE | dominant wait |
|---|---|---|---|---|---|---|---|
| osv-vu128-r1 | 762 | **0.00** | 137 | 10.1 | 25.8 GB | 0 / 0 | **AioUringCompletion 99.2%** |
| osv-vu192-r2 | 160 | **0.00** | 201 | 9.4 | 37.4 GB | 0 / 0 | **AioUringCompletion 99.5%** |
| osv-vu192-r3 | 149 | **0.00** | 200 | 9.4 | 37.4 GB | 0 / 0 | **AioUringCompletion 99.5%** |

Every wedge: no TEST RESULT within the 360s cap, ~99.5% of backends blocked on
`LWLock/AioUringCompletion`, **device completely idle**, CPU nearly idle — and **memory perfectly
healthy** (zero OOM, zero EMFILE, ~10MB/backend, 25-37 GB free and stable). This is a
stalled/lost io_uring completion, **not** memory exhaustion: it is **NOT** a regression of the
footprint fix and **NOT** the pre-fix VU64 OOM (which had an explicit OOM console message and
0.5GB free). It is intermittent (VU128 wedged 1/3, VU192 2/3, VU32/64 0/5), which is consistent
in kind with the a2a's "intermittent low-mode" — but here it is reproducible enough to chase, and
the wait event names the exact lock.

**This is the highest-value next target**, and it is a liveness bug, not just a perf gap.

---

## Equal-cache basis, and a REFUTED hypothesis (recorded because it nearly became a false claim)
`OSV_ZFS_ARC_MAX` **does not exist** on this base (git-grepped; it lives only on
`gh-fork/bench/zil-hires-ab`), so the a2a's "matched 32GiB ARC" was never enforced on the OSv
side. I added a default-on ARC probe (printf, not verbose-gated debugf) and measured.

An idle OSv guest shows `arc_c=2047MB` with 47GB free — which looks like a crippling cap, and the
hypothesis "OSv cannot use its RAM for page cache, so the VU32 gap is a 16x cache deficit" is very
attractive. **It is false.** 2047MB is the idle FLOOR (`arc_c_min = allmem/32` = 64GiB/32 = 2GiB
exactly, arc.c:8042; `arc_c = arc_c_min` at init, arc.c:8103), and `arc_adapt` (arc.c:5108-5124)
grows it on demand. Driven with real demand: `arc_size 19 → 2786 → 4876 → 6572 → 7460 → 8290 MB`,
and **in the VU64 cell it reached `arc_c=28,748MB / arc_size=28,183MB`**. OSv's ARC uses the RAM.

Consequences: (a) **no "OSv can't cache" finding** — publishing one would have been worse than
leaving #4 open; (b) the VU32 gap is **not** a cache artifact, so #4 stayed open and the
durable/nondurable discriminator is what actually answered it; (c) ARC parity is therefore **equal
CEILING, 32GiB both arms** (OSv measured `arc_c_max=32767MB`; Linux `zfs_arc_max=34359738368`).
Capping Linux to 2GiB — which the idle reading would have justified — would have pinned Linux at
its floor while OSv grew to ~28GB, handicapping Linux and inflating OSv: precisely the error class
behind this campaign's already-retracted "2.9x faster". Linux's `arc_c` also starts at a ~2GB
floor (2,106,834,944), independently corroborating the mechanism. Detail: `ARC-FINDING.md`.

---

## RESOLVED-LEVER PROOF (mandatory, per arm, from the console — never inferred from the cmdline)

### OSv arm (per cell; excerpt from `cells/osv-vu64-r1.leverproof.txt`)
```
BOOT IMG: /work/img-fix  MEM=64G CPUS=32 SB=16GB MAXCONN=400 IOMETHOD=io_uring SYNCCOMMIT=on FSYNC=on
BOOT IMG SHA: bcfd7058e7cf38a6 loader=d6f39b285be8ef13
FP_PROBE:            FPPROBE started interval_s=000000000000000a
OSV_WAKE_PULL:       WAKE_PULL ON
OSV_WAKE_LOCAL:      WAKE_LOCAL off
OSV_BLK_MQ_COMPLETE: virtio-blk completion mode=per-queue num_queues=32
OSV_ZIO_INTR_THREADS: z_null-INTERRUPT taskq count=1 / z_flush-INTERRUPT taskq count=1
OSV_ZIL_FLUSH_INLINE: inline flush completion=0 (0=dispatch to INTERRUPT taskq)
OSV_ZIL_COMMIT_TIMEOUT_PCT: commit window pct=0 (0=default 10)
OSV_ZIL_WAKE_UNLOCKED: zil wake fan-out mode=under-zl_lock (baseline)
FORKFLAG OSV_FORK_TIMING unset, default 0
FORKFLAG OSV_FORK_RANGE_BS unset, default 1
FORKFLAG OSV_FORK_LARGE_SHARE unset, default 1
ARCPROBE arc_size_MB=28183 arc_c_MB=28748 arc_c_max_MB=32767 zfs_arc_max_MB=0 dirty_max_MB=3276
OSv v0.57.0-546-g1480fbee
```
**Binding PROVEN by control, not assumed:** a boot WITHOUT `--env=OSV_BLK_MQ_COMPLETE=1` printed
`mode=single num_queues=4`; WITH it, `mode=per-queue num_queues=32` — same image, otherwise
identical. That is positive proof `--env` reaches `getenv()` on this image.
`zfs_arc_max_MB=0` is the proof that `OSV_ZFS_ARC_MAX` has **no consumer** here.
The footprint fix is **compile-time** (`FORK_OVF_RECYCLE_DEFAULT=1`), and its execution is proven
by the FPTOT counters: `ovfrecycled_MB` = 509,772 (VU64) / 1,461,044 (VU192), which are
zero-by-construction in the BEFORE arm.
**Trap worth recording:** the probe emits one field per line as ZERO-PADDED HEX
(`per_as_KB=0000000000002800` = 10240 KB). A naive `grep FPTOT` sees only `live_as=`, and a naive
`int()` is wrong by orders of magnitude — either mistake silently fabricates the headline
per-backend number. Parsed explicitly in `fptot.py`.

### Linux arm (per cell; excerpt from `cells/linux-vu64-r1.leverproof.txt`)
```
PACKAGED_CLUSTER_RUNNING=0
zfs_arc_max_resolved=34359738368   arc_max_kstat=34359738368   arc_c_current=2106834944
zfs_version=zfs-2.2.2-0ubuntu9.5
ashift 12 | recordsize 8K | compression off | atime off | sync standard | logbias latency | primarycache all
kernel=6.8.0-139-generic  ncpu=32  memtotal_kB=65838592  nr_hugepages=0
```
Resolved GUCs read back out of BOTH running servers per cell (`pg_settings`, not the command
line): `io_method=io_uring`, `shared_buffers=16GB`, `max_connections=400`, `fsync=on`,
`synchronous_commit=on` (and `off/off` verified on the nondurable cells).
**A real confound this caught:** Ubuntu's `postgresql-18` package auto-starts its own `18/main`
cluster which OWNS `127.0.0.1:5432`. It both blocked our postmaster from binding the IPv4 address
the DNAT targets AND would have run a second live PG competing for CPU and the same NVMe during
every Linux cell. Stopped + disabled, and `PACKAGED_CLUSTER_RUNNING=0` is asserted every cell.

---

## One-variable discipline
Held identical: same m5d.metal, host-native qemu 7.2.22 (`-M pc -cpu host -enable-kvm`), 32 vCPU /
64 GiB both guests, raw NVMe passthrough (`cache=none aio=native format=raw`), ZFS
ashift=12/recordsize=8k/compression=off/atime=off/sync=standard/logbias=latency/primarycache=all,
32GiB ARC ceiling both, PG 18.6 both, `io_method=io_uring` both (SQL-verified), same HammerDB
TPROC-C 200wh/19GB schema (OSv 60,008,515 vs Linux 60,007,714 `order_line` rows), same driver,
2-min rampup + 5-min measure, hardened quiesce (two consecutive sub-1s CHECKPOINTs) before every
cell, fresh boot per cell, r1 always kept.

**Two deliberate, documented deviations:**
1. **libc: OSv=musl, Linux=glibc** — the same single caveat the a2a accepted.
2. **Dedicated NVMe per arm** (OSv nvme1n1, Linux nvme3n1) instead of sharing one. Justified by
   measurement: fio randwrite 8k/iodepth32/4jobs → 100,405 vs 100,831 IOPS (**0.4% apart**). This
   removes the pool rebuild between arms and enables **interleaved arms** (osv r1, linux r1, osv
   r2, …) so host drift hits both arms equally — run-order being the artifact the a2a's own
   post-mortem blamed for its first, wrong result.

---

## Honesty gate / limitations
- **Linux has high rep variance at VU64+** (465k/285k/237k at VU64; 490k/194k/204k at VU192) and
  declines across successive reps, suggesting a warm-up/thermal/host-drift component that the
  interleaving distributes but does not eliminate. OSv is much tighter (157-173k at VU64, 9%
  spread). Medians are reported; the Linux spread means the exact ratios carry real uncertainty,
  while the DIRECTION (OSv behind at every VU) is consistent across all 11 valid cell pairs.
- OSv p99 is missing at VU32-r1/VU128/VU192 (HammerDB gather artifact); latency comparison rests
  on the cells that produced it, where OSv's p99 is ~2-4x Linux's (32.5 vs 12.1 at VU32;
  26-62 vs 16-41 at VU64).
- `fsync=off` is a mechanism probe only — not a throughput claim for either system.
- **Not comparable to the a2a's absolute numbers**: different base, ARC measured instead of
  assumed, dedicated per-arm devices, interleaved order. The a2a reported 0.72x at VU32; this run
  measures 0.53x on a verified-equal-cache basis. Both say "OSv behind at VU32"; this one names
  the mechanism and adds a reproducible wedge.
- The wedge was seen 3 times but not root-caused to a line of code — named to a lock
  (`AioUringCompletion`) and a state (device idle, CPU idle, memory healthy), not yet to a cause.

## Harness incidents (logged, not hidden — full detail in HARNESS-INCIDENT.md)
A stale ON-BOX copy of `boot-ubuntu.sh` made the Linux arm build its pool on the OSv arm's NVMe
**twice**, destroying the OSv seed each time. The first occurrence produced a plausible
`OSv 305,319 vs Linux 183,565 = 1.66x OSv AHEAD` — **VOID**, caught only because that durable
cell reported `nvme_util=0.00`, which is physically impossible with `fsync=on`. Publishing it
would have been a spectacular false "OSv wins" headline. Root cause of my error: I verified the
file I had edited instead of the file the box would execute.
Three gates now run before any cell: a **script-sync gate** (md5sum every harness script on both
boxes vs local, refuse to sweep on mismatch), a **device-assignment gate**, and a **zero-IO
validity check** that auto-invalidates any durable cell with no device IO. A separate collection
bug (HammerDB's result line scrolling out of `tail -40` at high VU) silently voided a good Linux
VU64 cell; the collector now greps the result line explicitly. Cost: ~90 min of rebuilds. No
measurement from any broken window reached this report.
