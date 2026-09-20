# A2A-final run identity

## Boxes (Owner=agent-a2afinal, lava acct 769093516156, us-east-2a)
- i-005c5bfb32d8f12aa  m5d.metal (Debian 12, ami-0dc1629a58a7d6458) -- BOTH guests + host + instr
- i-0aee60adbbece9746  c5.4xlarge (Ubuntu) -- HammerDB 6.0 driver

## OSv base (VERIFIED)
- Branch: gh-fork/bank/fork-arena-real-reclaim @ OSV_SHA 43fcdca797bd364b2f2982df92140c9197f8c834
- apps @ 3f93f43 (seed_copy rofs-mode fix, mkdir(dst,0700) marker=1)
- bench-base-gate PASS: stack_guard=3, openzfs_cv_timedwait_hires=1, wake_pull_enabled=1,
  write_cache.empty=1, vfs_dentry_hash_lock_held=2, req_done_q=3, OSV_FORK_RANGE_BS=2, OSV_FORK_LARGE_SHARE=2
- Both leak fixes present: fd-reap (ac6a389d2) + arena overflow-reclaim (43fcdca79) + cross-AS coherence (c2e86203a)
- Leak probe DORMANT (OSV_LEAK_PROBE not set)
- usr.img 118,685,696 B (114 MiB), byte-identical to prior verified-good image

## io_method DECISION: io_uring BOTH sides (brief-mandated, one-variable)
- OSv PG18.6 default build lacked --with-liburing -> io_uring REJECTED at boot.
- REBUILT OSv PG with --with-liburing (USE_LIBURING=1), musl liburing 2.5 from source
  (nolibc disabled, kernel uapi headers via -idirafter), shipped liburing.so.2 into the image.
- SMOKE TEST PASSED: PG accepts connections, `show io_method`=io_uring, 50k-row INSERT
  (synchronous_commit=on) 194ms + CHECKPOINT (fsync via io_uring) 182ms, ZERO io_uring errors.
  OSv io_uring (core/io_uring.cc, 40 opcodes incl READ/WRITE/FSYNC) drives PG's AIO path cleanly.

## Substrate (ONE-VARIABLE: only OSv-vs-Linux changes)
- RAW NVMe PASSTHROUGH: /dev/nvme1n1 (838GiB instance-store) straight through as guest vblk1,
  cache=none aio=native, format=raw. NOT a raw-file-on-XFS (the prior invalidated approach).
- Host-native qemu 7.2.22 (-M pc, -cpu host, -enable-kvm) for BOTH guests (matched hypervisor).
- 32 vCPU / 64 GiB guest. ARC cap 32 GiB (OSV_ZFS_ARC_MAX=34359738368).
- ZFS: ashift=12 recordsize=8k compression=off atime=off sync=standard logbias=latency primarycache=all.
- PG GUCs (source=command line): max_connections=400 shared_buffers=16GB effective_cache_size=32GB
  max_wal_size=64GB min_wal_size=2GB checkpoint_timeout=15min checkpoint_completion_target=0.9
  log_checkpoints=on fsync=on synchronous_commit=on autovacuum=on io_method=io_uring.
- ALL OSv levers ON at boot: WAKE_PULL ON, OSV_BLK_MQ_COMPLETE per-queue num_queues=32, fork levers default-on.

## Methodology (corrects the prior a2a3lever invalidation)
- FRESH BOOT PER CELL (one guest boot per VU-level per rep). NOT multi-cell-per-boot (the artifact source).
- Keep ALL reps incl fresh r1 (do NOT void as cold). Report full set + median.
- Hardened quiesce: 2 consecutive sub-1s CHECKPOINTs before each cell.
- VU8/16/32/64, 3 settled reps each, both OSv and Linux.
- Capture p99 latency + wait profile + host CPU (mpstat/qemu) + iostat, not just NOPM.
- Watch for regressions: NO EMFILE (leak#1), NO OOM/monotonic-mem-drop (leak#2), NO VU32 dentry wedge (#1502).

## Dataset
- HammerDB TPROC-C 200 warehouses = 19 GB, built once on the raw-NVMe ZFS pool (persists across fresh boots).
