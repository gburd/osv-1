# ZIL-commit sub-phase decomposition: status

Box: i-059a8c1347bd1c46e  m5d.metal  us-east-2  Owner=agent-zildecomp
IP: 18.218.46.88
AMI: ami-0eff088391f589f50 (AL2023 x86_64, kernel 6.12)
NVMe for both arms: /dev/nvme1n1 (instance-store) -- verify on box

## Question
The OSv per-fdatasync ZIL-commit tax is +263.5us (prior run, RESULTS.md).
Which sub-phase owns it?
  B. VIRTIO_BLK_T_FLUSH round-trip
  C. commit-waiter WAKEUP hops (cv_broadcast -> waiter -> fsync thread)
  D. batch-window wait (should be ~0 single-threaded)

## Experiments (cheapest first, ONE variable each)
1. sync-mode sweep (zfs set): standard / disabled / always, BOTH OSv & Linux.
   - sync=disabled makes fdatasync a near-noop (no ZIL, no flush) -> isolates
     whether tax is entirely ZIL+flush.
2. FLUSH isolation via host disk cache mode (one variable): virtio-blk
   cache=none (real flush) vs write-cache off / cache=unsafe (flush=noop).
   - big drop => phase B (flush). little change => phase C (wakeup).
3. (last resort) gethrtime probes in zil.c ring buffer -- only if 1+2 ambiguous.

## Confound to carry: OpenZFS 2.4.2 (OSv) vs 2.3.4 (Linux). zio arch identical.

## Build notes (harness gotchas fixed on box)
The iowake osv-build.sh only inited submodules: open_zfs/openzfs, musl_1.2.1,
external/x64/*. The OSv kernel build ALSO needs: kbuild (kconfig conf tool),
musl_0.9.12 (libc/locale symlinks -> musl_0.9.12). Without them the build dies
at `Makefile.osv: No such file` (kbuild) and `libc/locale/catopen.c: No rule`
(musl_0.9.12). Fixed both, rebuilt.

Also: running host-setup.sh + zfs-setup.sh concurrently collided on the dnf
lock and on kernel6.12-tools conflict; zfs-setup needs --allowerasing for the
6.1 kernel and must run alone. Fixed.

Linux arm: OpenZFS 2.2.7 built against 6.1.182 LTS (installed, default kernel,
needs reboot to load module). NOTE: prior run reported 2.3.4; this run is 2.2.7.
Still a version confound vs OSv 2.4.2; same zio arch. Will note in results.

## Progress -- COMPLETE
- [x] box launched, built (fixed 3 missing submodules: kbuild, musl_0.9.12)
- [x] EXP1 sync-mode sweep: refuted B/C/D framing -- tax is a VFS scan, not ZIL
- [x] EXP file-size sweep: fdatasync p50 LINEAR in file size (11->490us)
- [x] Root cause: sys_fsync -> writeback_inode O(filesize) whole-file scan,
      flushes 0 pages for pwrite. Proven with page counters (flushed=0).
- [x] EXP2 host flush mode: device FLUSH (phase B) = ~32us, minor.
- [x] FIX applied (write_cache.empty() guard) + VALIDATED:
      V1 p50 flat ~100us across 8-512MiB (was 11->490), skipped=100%, scan gone.
      V2 mmapfsync PASS -- mmap durability preserved (scan still runs, cache
      non-empty, pattern verified on disk).
- [x] TERMINATED i-059a8c1347bd1c46e. Root vol-0fbc46f23efb88d45 GONE.
      Orphan check: 0 agent-zildecomp instances, 0 agent-zildecomp volumes.
      (One untagged 20GiB available volume predates run by a day, not mine.)

## VERDICT
The dominant OSv per-fdatasync ZIL-commit tax is NOT B (flush), C (commit-waiter
wakeup), or D (batch window). It is a VFS-layer defect above the ZIL:
sys_fsync's unconditional whole-file writeback_inode scan, O(filesize) per
fsync, flushing 0 dirty pages for write()/pwrite() workloads. Proven by
linear-in-filesize scaling and page-scanned/flushed counters. Flush (B) ~32us
and ZIL wakeup (C) are real but small and fixed. Fix (empty-cache guard)
collapses OSv syncwrite p50 from 363-449us to ~104us (below Linux 185us),
flat across file size, mmap durability intact.

Linux arm was rebooted-into (6.1 + OpenZFS 2.2.7, module loaded) but the OSv
fix validation superseded the need for the matched Linux number -- the fix is
proven against OSv's own pre-fix baseline and the target is now below Linux's
known 185us. Confound noted: OSv OpenZFS 2.4.x vs Linux 2.2.7; irrelevant to a
VFS-layer (pre-ZFS) scan.
