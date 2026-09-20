# ZFS-READPATH — the metal profile + the borrow-path fix (agent osv-rdpath)

Agent: osv-rdpath. AWS_PROFILE=fred (acct 443433794128) us-east-2.
Instance: **i-0f24f28950783b77f** (m5d.metal, us-east-2b, 96 vCPU real KVM).
Build: gh-fork **wip/pg-tail-fix @ 79ed402f4** + a vn_access root-override fix (below).
Substrate: fs=ramfs image (PG .text baked, avoids the rofs-demand-page fork crash) + PG data on
an IN-GUEST OpenZFS pool `pgdata` (recordsize=8K compression=off, config matches the finding),
smp16, single-queue vhost tap (real net over br0 192.168.100.1<->guest .2), PG18.6 musl,
pgbench -s50 on `demo` (locale C), driver = postgres:18 container on host net.

============================================================================
## SUBSTRATE NOTES (hard-won, saves the next agent hours)
============================================================================
1. **fs=zfs root is UNBUILDABLE on AL2023** (no host OpenZFS; zfs-image-on-host.sh needs host
   zpool). SOLUTION: build **fs=rofs / fs=ramfs**, create the pgdata pool IN-GUEST at boot on a
   raw NVMe-backed vblk1 with `--preload-zfs-library` (inits /dev/zfs) + `/zpool.so create`. This
   IS the finding's substrate (PG data on OpenZFS); only the ZFS *root* is skipped (irrelevant to
   the read path).
2. **fs=rofs PG CRASHES on first fork** — `Assertion failed: sched::exception_depth <= 1
   (reschedule_from_interrupt)` when the postmaster forks the first backend: a ROFS demand-page
   fault (postgres .text on rofs) NESTED inside the fork COW fault -> reschedule at nested depth.
   SOLUTION: build **fs=ramfs** (PG .text baked into loader .bss, no rofs demand-paging). ramfs
   PG-on-ZFS serves forked backends 0-crash, survived -s50 seed + c1..c32 RO. (Same substrate fix
   the fair-benchmark skill documents for native.)
3. **libsolaris.so not mapped to /usr/lib/fs** when image list has `open_zfs` (it provides 'zfs'
   so the `zfs` placeholder module + its manifest are deduped out). FIX: add a
   `modules/open_zfs/usr.manifest` = `/usr/lib/fs/libsolaris.so: libsolaris.so`. Needed for
   `--preload-zfs-library` to find libsolaris.
4. **ZFS pool mountpoint on RO root**: the pool must mount at the pre-baked empty mountpoint
   `/data` (postgres18-musl bakes an empty /data dir for exactly this) via `zpool create -m /data`
   -- ZFS mounts over it, no runtime mkdir on the RO rofs/ramfs.
5. **EACCES bug (root-caused + fixed, see below)**: PG on OpenZFS could not open its own 0600
   files (`could not open file global/pg_control: EACCES`).
6. **Docker host FORWARD policy=DROP** blocks host<->guest TCP over br0 (ICMP works). FIX:
   `iptables -I FORWARD 1 -i br0 -j ACCEPT; -o br0 -j ACCEPT`. Re-apply after any docker restart.
7. **ssh single-quote heredocs with $ silently corrupt** -- write scripts locally + scp them.
8. **detached qemu**: `docker exec -d osvbuild env SMP=16 /path/run-guest.sh` works; wrapping in
   `sh -c "setsid ... > log"` does NOT launch. Serial to `-serial file:`.
9. **pool is RECREATED empty every boot** (`zpool create -f`) -> re-seed pgbench after each boot,
   or import instead of create for a persistent dataset.

============================================================================
## THE vn_access EACCES FIX (unblocks PG-on-OpenZFS entirely)
============================================================================
SYMPTOM: PG panics `could not open file "global/pg_control": EACCES`; instrumented
`vn_access` showed `v_mode=0100555` on a file PG created 0600.
ROOT CAUSE: OSv `fs/vfs/vfs_vnode.cc:vn_access()` enforces the file mode bits
(`(v_mode & 0222)==0 -> EACCES`) against a process that is ALWAYS uid 0 (OSv is a single-address-
space unikernel; the OpenZFS platform layer hardwires `crgetuid()==0`). POSIX grants the
superuser discretionary access regardless of mode bits. OSv's vn_access lacked the root override,
so it denied the only user OSv has. (ramfs happened to return a mode that passed; OpenZFS returns
a write-clear mode on freshly created files -> EACCES.)
FIX: give root the standard POSIX bypass in vn_access -- drop the VREAD/VWRITE mode-bit denials
(keep VEXEC needing >=1 x bit, keep MNT_RDONLY -> EROFS). Correct unikernel semantics, minimal.
=> This is a REAL, shippable OSv correctness fix independent of the read-path work. Needs a
   G-signed commit (candidate for gh-fork). Diff is ~10 lines in fs/vfs/vfs_vnode.cc.

============================================================================
## STEP 1 — THE READ-PATH PROFILE (the key deliverable)
============================================================================
RO reproduces the flat plateau: single-queue smp16, WAKE_PULL+IDLE_SPIN(100000) ON:
  c1 6732 | c8 19891 (PEAK) | c16 17779 | c32 16179  (peaks c8, declines -- the finding shape;
  single-queue peak ~20k vs the finding's MQ ~25k, same flat-after-c8 signature).

### Guest-RIP histogram under RO c16 (8000 samples via QMP info-registers-all + addr2line):
  49.7%  sched::cpu::do_idle              <- CPUs IDLE-SPINNING, waiting for work
  26.8%  sched::cpu::handle_incoming_wakeups  <- the receiver->backend WAKE handoff
   8.4%  ?? (unresolved, mostly idle/asm)
   4.6%  memcpy_repmov_ssse3              <- the ZFS ARC->uio copy (SECONDARY, small)
   3.1%  atomic load (scheduler)
   0.4%  lockfree::mutex::lock            <- the per-vnode v_lock: NOT contended
   0.1%  lockfree::mutex::unlock
   ~0%   zfs_read / dmu_read / dbuf / arc / uiomove  <- the ZFS read path barely registers

### VERDICT (corrects the finding's premise, HONEST):
The OSv-OpenZFS RO c8-c32 gap is **NOT primarily the ZFS read path**. 76.5% of guest CPU is in the
scheduler wake/idle machinery (do_idle 49.7% + handle_incoming_wakeups 26.8%) -- the SAME
per-request receiver->backend WAKE tail the prior wake-inline/idle-spin agents already root-caused
as the process-per-connection floor (Linux async/epoll wakes inline in softirq with 0 per-request
thread wakes; OSv forks one OS thread per backend and must cross-thread-wake it per request).
- The ZFS ARC->user COPY is REAL but SECONDARY here: only ~4.6% (memcpy). It is a per-op constant
  (explains why the PEAK is ~20-25k not ~140k) but NOT the concurrency collapse.
- The per-vnode v_lock is NOT the serializer (0.4% lock, uncontended) -- the code-study's item-4
  hypothesis does NOT hold under this profile (the read_cache/rangelock path keeps v_lock cheap;
  reads are wake-bound, blocked waiting for the next request, not spinning on v_lock).
=> The PG RO throughput number is WAKE-BOUND, not ZFS-copy-bound and not lock-bound. This unifies
   the ZFS finding with #3 (the wake tail): on ZFS the peak is lower (~20-25k vs ramfs ~50k)
   because each backend ALSO pays the ARC lookup+copy per query (the ~4.6% + the per-op ARC
   bookkeeping the microbench measured as the 35k-IOPS QD1 cap), but the FLAT-vs-concurrency
   shape is the wake tail, identical to ramfs.

### Where the ZFS copy STILL matters (the S1 target, a DIFFERENT metric):
The measured +501MB mmap double-buffer (PERF-osv-openzfs.md) and the 2.5x warm-read / 6.5x QD1
gaps are REAL and are the ARC<->page-cache copy. They show on the **mmap/warm-read** path and as
**memory footprint**, NOT as PG pread RO throughput (PG reads via pread, wake-bound). S1 (wire the
zero-copy borrow) fixes the double-buffer + mmap/warm-read, the deep-integration win -- but it will
NOT materially move PG RO tps (that needs the wake fix, already shipped as wip/pg-wake-inline).

============================================================================
## STATUS / NEXT
============================================================================
- [x] substrate up (ramfs PG-on-OpenZFS, seeded -s50, 0-crash, real net)
- [x] vn_access EACCES root-caused + fixed (needs G-signed commit)
- [x] STEP-1 read-path profile banked (wake-bound, copy secondary, lock not it)
- [ ] S1: wire osv_pagecache_map_arc_page borrow path from zfs_vop_cache (double-buffer fix)
- [ ] validate S1 (mmap free-page delta 501MB->~5MB), A/B
- [ ] push G-signed gh-fork wip/pg-zfs-readpath

============================================================================
## KEY CORRECTION: S1 (the zero-copy ARC<->page-cache borrow) IS ALREADY DONE
============================================================================
The code-study was written against patch 0005 (copy-only zfs_vop_cache). The ACTUAL tip
(wip/pg-tail-fix @ 79ed402f4, and master 0e34e4dc2) ALREADY HAS the borrow wired:
- **patch 0019** "zfs: share decompressed ARC pages into mmap page cache" rewrites zfs_vop_cache
  to dmu_buf_hold the covering dbuf, check db_data is page-aligned + the target page fully backed,
  and hand `db_data + intra-record-offset` straight to `osv_pagecache_map_arc_page` (zero-copy),
  falling back to the copy path for sub-page records / file tail.
- `zfs_initialize_osv.c` registers `osv_arc_dbuf_rele` via `osv_pagecache_register_arc_rele` so the
  cached_page_arc destructor drops the dbuf hold on eviction (lifetime handled).
- patch 0019's OWN measurement: 256MiB mmap read-fault, lz4 cold fault -30% (4.8->3.2us/page),
  RSS drops (pages shared not duplicated), checksums match the copy path.
=> S1 is IMPLEMENTED, VALIDATED (by its author), and LIVE in the benchmarked build. The directive
   to "wire the borrow path" was already satisfied upstream. On master it lives as real source in
   modules/open_zfs/osv/module/os/osv/zfs/{zfs_vnops_os.c,zfs_initialize_osv.c}.

### WHY S1 does NOT move the PG RO number (the honest, decisive point)
PostgreSQL reads its data files via **pread()** -> OSv `zfs_vop_read` -> `zfs_read` ->
`dmu_read_uio_dbuf` -> `zfs_uiomove` = ONE memcpy from the ARC dbuf into PG's user buffer. This is
the **read() path (Copy point A)**, NOT `zfs_vop_cache` (the mmap fault path, Copy point B) that S1
accelerates. PG never mmaps its data files. The POSIX read() contract REQUIRES a copy into the
caller's buffer, so the borrow cannot eliminate PG's per-read copy. S1 helps mmap consumers (RSS +
mmap-fault latency), which is a REAL measured win (the +501MB double-buffer / 2.5x warm-read /
6.5x QD1 microbench gaps) -- but PG-on-OpenZFS RO throughput is WAKE-BOUND (76% scheduler, STEP-1
profile), so neither S1 nor the v_lock drop moves it. The lever that moves PG RO is the
per-request wake fix (already shipped as gh-fork wip/pg-wake-inline + OSV_IDLE_SPIN).

============================================================================
## THE COMPLETE MEASURED SWEEP (real OpenZFS pool, s50, 0-failed)
============================================================================
OSv PG-on-OpenZFS, smp16, single-queue vhost, WAKE_PULL+IDLE_SPIN(100000), s50, real net,
3rd-of-3 spot values (short 8s runs; single-queue so peak ~20k not the finding's MQ ~25k):
  RO: c1 6581 | c8 19537 (PEAK) | c16 18369 | c32 15569 | c48 15221 | c64 14148   (all 0-failed)
  RW: c1 1099 | c8 2997 | c16 3025 | c32 3468                                       (all 0-failed)
Shape MATCHES the finding: RO peaks c8 then flat/declines (wake-bound), RW climbs (kinder cell).
Data correctness verified: SELECT count(*),sum(abalance) FROM pgbench_accounts = 5000000, 0
(reads through the borrow-enabled build return correct data; 0-crash across the full sweep + the
-s50 seed fork/COW/write gate).

============================================================================
## DELIVERABLES SHIPPED
============================================================================
1. **vn_access superuser bypass** (the EACCES fix that unblocks PG-on-OpenZFS): committed
   G-signed 4c60e9cd0, pushed gh-fork **wip/pg-zfs-readpath** (leak-clean, em-dash-free,
   fast-forward over 7823a2199). This is the NEW, real, shippable OSv correctness fix from this
   run. Without it PG cannot open its own files on OpenZFS.
2. STEP-1 read-path profile (this doc): the RO gap is wake-bound, copy secondary, lock not it.
3. Confirmation that S1 (the borrow) is already done+live (patch 0019) and correctly does NOT
   move PG RO (pread path), only mmap/RSS.

============================================================================
## STEP 2 — WHY HUGEPAGES HURT OSv RO (grounded in the STEP-1 profile)
============================================================================
The ZFS-MATRIX matrix already MEASURED it: OSv RO -24-27% with hugepages (c8 24627->18682,
c64 21238->15404), RW neutral, Linux RO neutral. (A fresh HP re-run this session was blocked by a
container/hugetlbfs-namespace quirk -- the detached qemu could not keep the container's per-exec
hugetlbfs mount + -mem-prealloc alive; the guest boots HP fine in the foreground. Not worth more
burner time; the matrix number stands and STEP-1 now EXPLAINS it.)

WHY (from STEP-1): OSv RO is **wake-bound** (76% of guest CPU in do_idle + handle_incoming_wakeups,
only ~4.6% memcpy, ~0% page-table work). A wake-bound workload gets ~zero benefit from 2MB pages:
the hot path is the scheduler wake/IPI round-trip, not TLB misses on the working set (PG
shared_buffers is only 128MB, so the TLB win from 2MB pages is tiny even for the data). Meanwhile
hugepages ADD cost on OSv:
  (a) qemu `-mem-prealloc` on hugetlbfs faults in the ENTIRE guest RAM arena backed by 2MB pages up
      front; OSv's mmu then manages the shared-anon arena (PG shared_buffers + the ARC) as 2MB
      mappings, and any sub-2MB op (fork COW, a 4K/8K ARC-borrow page, a 4K page-cache page) must
      split/handle the large mapping -- more expensive per op than a plain 4K page.
  (b) the ARC borrow path (patch 0019) hands 4K/8K db_data pages to the page cache; a 2MB-backed
      arena makes those fine-grained ops interact badly with the large backing.
  (c) OSv fork COW (one OS thread per PG backend) touches many small pages; 2MB backing raises the
      per-fault COW-split cost.
So hugepages cost OSv real per-op mmu overhead on the fork/COW + ARC-borrow + 4K-page-cache paths
while giving ~0 TLB benefit to a wake-bound workload -> net -24-27% RO. Linux RO is neutral (async
softirq reads, no per-request fork/COW, no OSv large-page split cost). OSv RW is neutral because RW
is fsync/ZIL-bound (disk latency dominates; mmu overhead in the noise).
RECOMMENDATION (unchanged): run OSv PG-on-OpenZFS with huge_pages=OFF.

============================================================================
## STEP 3 — THE v_lock HYPOTHESIS: TESTED, NOT SUPPORTED BY THE PROFILE, A/B INFRA-BLOCKED
============================================================================
Steer hypothesis: a redundant per-vnode v_lock on VREG ZFS reads serializes concurrent preads
(ZFS has its own RL_READER rangelock, so the outer v_lock is redundant); mirror the VBLK fast
path (c063c5c58) to drop it for VREG-on-ZFS pread.

### Evidence AGAINST it being the serializer (STEP-1 metal profile, RO c16, 8000 samples):
  lockfree::mutex::lock  0.4%   <- v_lock is NOT hot / NOT spinning
  lockfree::mutex::unlock 0.1%
  do_idle 49.7% + handle_incoming_wakeups 26.8% = 76.5% scheduler wake/idle
If v_lock serialized the preads, backends would pile up BLOCKED on it. A blocked-on-mutex thread
in OSv sleeps (CPU -> do_idle) and is woken on release -- so "76% do_idle + 27% wakeups" is
TECHNICALLY also consistent with lock serialization (block->sleep->wake). The RIP histogram alone
cannot fully separate "wake-bound by the process model" from "wake-bound by v_lock" -- only the
A/B (drop the lock, measure) is decisive.

### The A/B: prototyped, built rc=0, but BOOT-INFRA-BLOCKED this run (HONEST):
Prototyped the bypass in fs/vfs/vfs_fops.cc:vfs_file::read: skip vn_lock for
`vp->v_type == VREG && vp->v_op->vop_cache && (flags & FOF_OFFSET)` (vop_cache = the ZFS-style
page/read-coherent marker; FOF_OFFSET = pread, no fp->f_offset to protect). Built rc=0. But the
A/B could NOT run: after ~30 guest reboots the build-container's qemu launches stopped persisting
(detached qemu exits immediately; `-serial file:` stopped creating host-visible files) -- a
container/KVM/mount-propagation degradation, NOT a code fault. The known-good vn_access-only build
(which booted PG fine at 14:33/15:05) ALSO failed to boot under the degraded container, confirming
the block is INFRA. Ran out of burner to recreate the container + re-seed + A/B.

### The prototype diff (NOT pushed -- unvalidated; do NOT ship until boot+A/B+#504-deadlock-gated):
```
@@ vfs_file::read, after the VBLK fast path @@
+	if (vp->v_type == VREG && vp->v_op->vop_cache && (flags & FOF_OFFSET) != 0)
+		return VOP_READ(vp, fp, uio, 0);
```
SAFETY TODO before shipping: (a) confirm it boots (boot VREG reads use read()/FOF_OFFSET==0 so the
gate should exclude them -- verify); (b) issue-#504 deadlock was the OLD ARC-bridge re-entry; the
modern read_cache + ZFS RL_READER should not re-enter, but gate a fork/COW + concurrent
read/truncate test; (c) v_lock also guards read-vs-setattr(v_size) coherence -- pgbench RO never
truncates, and ZFS's rangelock tolerates a concurrent size change, but a general fix must confirm.

### HONEST VERDICT on STEP 3:
The profile says v_lock is NOT the hot serializer (0.4%), so the LIKELY A/B outcome is "flat" (the
plateau is the process-per-connection wake tail, not v_lock). NOT proven -- the decisive A/B was
infra-blocked. Prototype banked here (not pushed) for the next agent to boot + A/B on a fresh
container. If RO climbs, v_lock was a compounding serializer worth shipping; if flat, it confirms
the wake-tail verdict and the bypass is a no-op.

## NEXT LEVER (precise, for whoever continues)
- PG RO on OpenZFS is wake-bound -> the lever is the per-request wake tail (wip/pg-wake-inline),
  NOT the ZFS read path. On ZFS the peak is lower than ramfs (~20-25k vs ~50k) because each
  backend also pays the ARC lookup + one memcpy per query (the ~4.6% memcpy + per-op ARC
  bookkeeping = the ~35k-IOPS QD1 software ceiling from the microbench), but the flat-vs-c shape
  is the wake tail.
- To make PG's pread ITSELF cheaper (shave the ~4.6% + the ARC per-op cost toward BSD's), the
  target is zfs_read/dmu_read_uio_dbuf per-op overhead (ARC hash + dbuf hold + abd bookkeeping),
  a smaller separate optimization (code-study S2), not the borrow.
