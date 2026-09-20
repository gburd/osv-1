# M1 HammerDB spin-verdict run — PROGRESS

Question: does OSV_IDLE_SPIN isolate win (+56-140% durable-write op/s) transfer to HammerDB TPROC-C,
or does idle-spin steal query cycles? Final M1 verdict.

## Box IDs (updated as launched) — TERMINATE ALL
- METAL: (pending) m5d.metal us-east-2 Owner=agent-spinverdict
- DRIVER: (pending) c5.4xlarge us-east-2 Owner=agent-spinverdict

## Substrate (matched to isolate)
- Debian 12 ami-0dc1629a58a7d6458 (NEVER Amazon Linux), native qemu 7.2 -M pc
- raw NVMe passthrough (cache=none aio=native, /dev/nvmeXn1, NOT raw-file-on-XFS), num_queues>1
- 32vCPU/64GiB guest, PG 18.6 musl, 200wh/~19GB, ZFS ashift=12 recordsize=8k sync=standard, 32GiB ARC both
- io_method=sync, 12 GUCs source=command line

## Build hygiene (STEP4 failure was a corrupted build w/ wrong seed_copy pin)
- Re-pin apps to 3f93f43 after checkout (bench/writedepth:apps records 5cb1903 = PRE seed_copy fix)
- chown submodule/openzfs user-owned BEFORE zfs patch-apply
- bench-base-gate.sh must PASS; verify OSV_IDLE_SPIN in core/sched.cc
- CLEAN build

## Plan
1. Launch metal + driver (Owner=agent-spinverdict)
2. Build OSv PG18 image on metal (clean, apps@3f93f43), Linux PG on same NVMe for A/B
3. Seed ZFS pool once (raw passthrough); capture exact errno+path if seed fails, do NOT chmod 0777
4. HammerDB build 200wh
5. Sweep OSV_IDLE_SPIN {baseline, moderate ~50-100k, 500000} x VU {16,32}; +VU8/64 at best spin
6. vCPU-util discriminator: mpstat on metal + thread-state sample (spin cycles vs query cycles)
7. Verdict + terminate all, confirm 0 orphans

## Status log

## Harness understanding (from writedepth + m1confirm-harness)
- Build: fedora:39 docker container 'bld' (toolchain); boot: NATIVE Debian qemu 7.2 -M pc
- build-image.sh (m1confirm) ALREADY re-pins apps to 3f93f43 + prebuilds ZFS .so + base guards
- OSv PG arm: pg-boot.sh seed|run; seed=create pool+seed_copy+export, run=import+mount+postgres
  - RAW passthrough substrate: hd1 = /dev/nvmeXn1 directly (cache=none aio=native), num-queues=NQ>1
  - (m1confirm used /mnt/nv/pgdata.raw raw-file-on-XFS; task requires raw passthrough like isolate)
- Linux arm: linux-arm.sh installs zfs-dkms on host, matched pool on same raw NVMe
  - NEED: Linux PG 18.6 (not just syncwrite) for the HammerDB A/B. Build/install PG on host.
- HammerDB: driver c5.4xlarge, HammerDB-6.0, hdb.sh build 200wh / run <vu> <tag>; NOPM from log
- seed_copy@3f93f43: 0700 dirs 0600 files, ignores rofs modes = CORRECT (STEP4 EACCES was 5cb1903)
- bench-base-gate.sh checks 9 required OSv fixes incl #1502 dentry (VU32 wedge), #1509 virtio-blk MQ

## BOX IDS (launched 2026-09-16T11:03:39Z) — Owner=agent-spinverdict, us-east-2b, acct 769093516156
- METAL:  i-0d2d3a537feb2c14d  m5d.metal   (raw instance-store NVMe passthrough)
- DRIVER: i-0dab66e8bded551c4  c5.4xlarge  (HammerDB driver)
TERMINATE BOTH ON EXIT.

## Status log
- 11:03Z launched metal + driver(Debian). Driver relaunched Ubuntu 24.04 i-0d72ade3bc1516018 (HammerDB needs glibc 2.38).
- Metal host-setup OK: DATADISK=/dev/nvme0n1 (raw passthrough), /work=nvme1n1 XFS, docker, tap0/br0 DNAT 5432.
- Build (bench/writedepth): base-gate PASS (OSV_IDLE_SPIN present + all 9 fixes). apps=3f93f43, openzfs=6330a45b.
  OpenZFS 43/43 patches applied CLEAN, 0 skipped. Building ZFS .so set then full PG18 image.
- Driver Ubuntu: HammerDB 6.0 OK (hdb_version), postgresql-client installed.

## SEED ATTEMPT 1 (raw /dev/nvme0n1 passthrough): guest DIED mid-seed_copy, NO error printed
- Clean build, seed_copy@3f93f43 (correct). Guest booted 337ms, created+mounted pool.
- zfs list showed pgdata 444K (empty). ZIL env banners printed (=first commit fired during copy).
- Then qemu EXITED silently (no EACCES, no panic, no export, pool stayed ~444K). Same class as prior
  STEP4 "hangs mid-copy". NOT the seed_copy EACCES (that was the old 5cb1903 build).
- Investigating: capture qemu exit code + full serial; try seed with logging.

## ROOT CAUSE of seed failure ISOLATED (2026-09-16 ~11:28Z)
seed_copy /data-seed -> /tmp/pg (RAMFS): WORKS. PostgreSQL 18.6 started, read the seeded
cluster, "database system is ready to accept connections". So:
  - seed_copy READ of /data-seed (rofs) OK
  - seed_copy copy engine OK
  - ramfs write OK
seed_copy /data-seed -> /data/pg (ZFS mount): writes NOTHING, no error, `zfs get used`=444K.
=> The blocker is specifically OSv ZFS-WRITE-through-VFS on a freshly-created pool: plain
   open()/write() into the ZFS zpl silently persists 0 bytes (and does not error).
   This is the "OSv-ZFS-write robustness gap" the prior STEP4 report flagged, NOT a seed_copy
   or build-hygiene bug (build is clean, apps=3f93f43, 43/43 patches, PG in image).
NOTE: the isolate (STEP1-3 syncwrite) wrote to ZFS fine via zfs-bench.so's direct path; the
   VFS zpl write path (what seed_copy + a live postgres -D /data/pg use) is the one that fails.
   This means even if seeding were worked around, a live PG writing WAL/heap to /data (ZFS) would
   hit the same silent-write-loss => HammerDB on OSv-ZFS is not currently runnable on this build.

## SEED RESOLVED (2026-09-16 ~11:33Z) — STEP4 blocker was the OLD build, not a real ZFS bug
Full production flow on the CLEAN build (apps=3f93f43) works end-to-end:
  BOOT1: zpool create + seed_copy /data-seed /data/pg + zpool export  -> RC=0
  BOOT2: zpool import + zfs mount + postgres -D /data/pg  -> "ready to accept connections"
The `zfs get used=444K` after seed was a STALE property reading (ARC/not-yet-synced), NOT
write loss: PG reads back the full cluster fine. The prior STEP4 "seed EACCES / hang" was the
corrupted 5cb1903 build, exactly as the task hypothesized. Contradicting my earlier ZFS-write-loss
note. Proceeding to: PG run-mode + driver connectivity + HammerDB 200wh + spin sweep.

## Status 11:37Z: PG up (run mode), driver connectivity OK, HammerDB buildschema 200wh RUNNING.
Next: while it loads, build the spin-sweep harness (baseline/moderate/500000 x VU16/32 +VU8/64 best)
+ vCPU-util discriminator (mpstat on metal + guest thread-state sample). Then Linux PG arm on same NVMe.

## Spin values to sweep (record boot-printed default first):
- baseline = base default (record from boot line)
- moderate = 50000-100000
- aggressive = 500000
VU {8,16,32,64}; primary discriminator cells VU16/VU32 (declining region).

## 11:47Z: TPCC SCHEMA COMPLETE (200wh, 19GB) on OSv-ZFS pool. Quiescing for the sweep.

## 11:57Z Teardown solved + baseline confirmed
- Unclean pkill -> 4min WAL crash-recovery per boot. FIX: checkpoint idle DB before pkill -> next
  boot redo done in 0.01s, PG ready 15s. Baked into sweep kill_guest (checkpoint x2 then pkill).
- SANITY: VU16 spin=10000 (baseline default) = 119,419 NOPM / 274,936 TPM. Pipeline fully works.
- Launching PRIMARY SWEEP: spins{10000,100000,500000} x VU{16,32} x reps{1cold,2settled}, ramp2 dur3.
  mpstat discriminator per cell. Results -> .local/spinverdict/results/

## 12:58Z Poll-ceiling bug fixed (vucomplete over-waited 25min/cell -> capped 40s)
- Cell wall time now ~5.3min (was 25). Also: kill_guest MID-run left dirty pool -> 4min recovery;
  fixed by settle(15s)+checkpoint x2 before pkill (only ever kills an IDLE DB in normal flow).
- Observed NOPM variance at VU16 spin=10000 across runs: 116k, 88k, 144k (~40% spread). 200wh
  TPROC-C is high-variance (NULL-wait bound MIX, as prior runs noted) -> need 3 reps + medians.
- Restarting sweep: spins{10000,100000,500000} x VU{16,32} x reps{1cold,2,3}, ramp2 dur3.

## 15:14Z DECISIVE a2a-methodology cross-check (measurement-integrity finding)
Read .local/a2a3lever/ (RESULT.md, LIVE.md, raw/). The historical M1 headline
("OSv 104k@VU8 -> 64k@VU16 declines; Linux 159k->269k scales; VU32 wedges") was measured
PER-BOOT, NOT per-cell:
  - Only TWO console-run-*.log exist for the whole OSv side. console-run-132750 (13:27:55) served
    ALL a2a-all-levers cells (VU8 r1-r4, VU16 r1-r3, VU32) across 3h22m to 16:49:49 on ONE boot.
  - That single boot's console has 109 "autovacuum worker took too long / not accepting" markers
    = progressive wedging across the run, the SAME cumulative degradation this run reproduced.
  - a2a VU8 raw: r1=158830, r2=101898, r3=104640, r4=108688. They VOIDED r1 as "cold-inflated" and
    took the median of r2-r4 (~104k). But fresh-boot data here shows r1 is the CLEAN number and
    r2+ are the CONTAMINATED (degraded) ones -> they discarded the clean cell and kept degraded ones.
  - shape-fix VU16 "wedged... autovacuum worker took too long... a SEPARATE OSv defect after many
    cells" = the SAME run-order wedge, mis-attributed to a distinct defect.
=> The historical "OSv declines while Linux scales" curve is built on run-order-contaminated cells.
   Fresh-boot VU32 spin=10000 here = 215,504 NOPM (vs the contaminated ~9k, and vs a2a's degraded
   ~64k@VU16). This reframes the M1 gap: it may be substantially a harness artifact.
NEXT (priority per reviewer): (1) confirm 215k with 3 fresh-boot reps; (2) fresh-boot VU8/16/32/64
   baseline curve - does OSv still decline?; (3) then the spin trio.
ISOLATE: the syncwrite isolate (OSv 1.5 vs Linux 13 lwbs, recycle-latency gap) was a single
   continuous workload, NOT multi-cell-per-boot -> likely still real. The recycle-latency deficit
   and the (artifact) HammerDB decline can both be true.

## 15:45Z DONE + terminated. See RESULT.md for full writeup.
- Fresh-boot VU32 spin=10000 = 215,504 NOPM (healthy) vs contaminated ~9k. The M1 decline is
  substantially a run-order/cumulative-degradation ARTIFACT (a2a ran all cells on 1 boot, 109 wedge
  markers, voided the clean r1). Within-boot decay: 169k->43k->0->0->0->0 (hard zero, reboot-resettable).
- Wedge signature at 0-NOPM: 33 KVM vCPUs S + 1 R, qemu ~0.65 vCPU busy (idle-WAITING not spinning),
  69 active PG backends, wait: LWLock:WALWrite=33 + NULL-wait=32 + CheckpointDone/WalSync. NOT idle-spin tax.
- Spin verdict UNRESOLVED (per-boot sweep uninterpretable); now secondary to the leak.
- Both boxes terminated, 0 orphans. Leak hunt handed off to a dedicated fresh-context agent (RESULT.md NEXT).
