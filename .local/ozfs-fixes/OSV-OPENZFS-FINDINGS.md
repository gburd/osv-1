# OpenZFS-on-OSv runtime bring-up: findings & fixes (wip/ozfs-runtime-fix)

## Phase A — early-boot abort root cause

Symptom: zfs_builder guest aborts right after the version banner with an empty
`[backtrace]`, before "Running mkfs...".

Root cause (symbolized with the non-stripped kernel + libsolaris.so):
SIGSEGV at `kstat_create+22` (`ksp->ks_ndata = ndata`, `mov %ebx,0x8(%rax)`)
with `ksp` = an unmapped garbage pointer.  The `conf_zfs=openzfs` build linked
the legacy BSD-ZFS kstat stub `bsd/.../opensolaris_kstat.o`, whose `kstat_t` is
16 bytes, to satisfy `kstat_create/install/delete`.  But every OpenZFS module
was compiled against the OSv SPL `kstat_t` in
`external/openzfs/include/os/osv/spl/sys/kstat.h` (~64 bytes: ks_data, ks_ndata,
ks_data_size, ks_flags, ks_update, ks_private, ks_private1, ks_lock).  OpenZFS
callers (arc_init/dnode_init) write ks_update/ks_private at offsets 32-56 of a
16-byte allocation, corrupting the malloc free list; the next kstat_create()
returns a garbage pointer and faults.

## Phase B — fix

Commit "zfs(openzfs): fix early-boot heap corruption from BSD kstat ABI
mismatch":
- Implemented OSv-native kstat_create/install/delete in
  `bsd/sys/cddl/compat/opensolaris/openzfs_osv_compat.c` using the correct
  OpenZFS kstat_t layout (virtual kstats; OSv has no /proc or sysctl consumer).
- Filtered the BSD `opensolaris_kstat.o` out of the openzfs `solaris` object
  list in the Makefile.

Result: zfs_builder boots, runs mkfs (creates + mounts pool `osv`), populates
it via cpiod, exports cleanly.  "cpiod finished", BUILD_EXIT=0.

## Phase C — raw NVMe throughput (m5d.metal instance-store, single vdev)

Raw fio ceiling (host, /dev/nvme0n1, O_DIRECT, 1M, QD32):
  seq write ~860 MB/s, seq read ~1835 MB/s (per instance-store NVMe).

OpenZFS-on-OSv (pool on /dev/vblk0 = raw NVMe partition, ashift=12,
compression=off, recordsize=1M), via scripts/bench/zfs-bench.cc:
  seq_write 8GB (> ARC): 828 MB/s   (matches raw ceiling)
  seq_write 4GB:         927 MB/s
  seq_read (ARC-warm):  3390-3544 MB/s

Verdict: OpenZFS on OSv hits expected NVMe write speed; reads are
ARC-accelerated to memory bandwidth.  Not TCG-slow, not MB/s-capped.

## Bugs found during bring-up

### Bug 1: zpool export mutex-owner assertion
`zpool export <pool>` aborts:
  Assertion failed: owner.load(...) == sched::thread::current()
  (core/lfmutex.cc: unlock: 221)
  #1 lockfree::mutex::unlock()
  #2 condvar::wait(lockfree::mutex*, sched::timer*)
  #3 <libsolaris .so, +0x83f5aa>
A mutex is unlocked by a different thread than locked it, during a condvar wait
in the export path (a taskq/worker-thread hands back a lock the caller holds).
Does NOT block create/mount/IO.  STATUS: under investigation.

### Bug 2: partition .0 vs .1 naming mismatch
OSv `read_partition_table` (fs/devfs/device.cc) names MBR partitions 0-based:
disk N partition slot 0 -> `/dev/vblkN.0`.  OpenZFS `zfs_append_partition`
(lib/libzutil/os/osv/zutil_device_path_os.c, patch 0014) appends `.1`.  A disk
whose pool partition is in MBR slot 0 is exposed as `vblkN.0` but zpool looks
for `vblkN.1` -> "cannot open '/dev/vblkN.1'".
The OSv image tooling puts its partition in MBR slot 1, so it lands at `.1` and
matches.  WORKAROUND used for the raw-NVMe bench: create the pool partition in
MBR slot 1 (a 1 MiB placeholder in slot 0, the big partition in slot 1) so it
becomes `/dev/vblk0.1`.  Proper fix TBD (align the two conventions).

### Bug 3 (fixed): zfs destroy / zpool export "dataset is busy" (EBUSY)
`getmntent`/`getmntany` on OSv were stubs returning EOF, so libzfs could not see
kernel-auto-mounted datasets; `zfs_unmount` skipped the unmount and the objset
stayed owned -> EBUSY on destroy/export.  Fixed in patch 0020: back
getmntent/getmntany with `osv::current_mounts()`.
