# ZFS RO read-path zero-copy WIRING - VALIDATED RESULT (agent osv-wire)

Copyright (C) 2026 Greg Burd

Instance: i-093102592a334ca9c (osv-wire-host, m5d.metal, us-east-2). Build box.
Branch banked: gh-fork wip/pg-zfs-readpath @ 7823a2199 (G-signed, leak-clean).

## 1. THE WIRING ALREADY EXISTS ON MASTER - and it is CORRECT.

The brief's premise (nothing calls osv_pagecache_map_arc_page; zfs_vop_cache
COPIES) is STALE. The zero-copy ARC-borrow read path is ALREADY MERGED on
upstream/master (0e34e4dc2, via PR #1423, which folded in patch 0019's content):

- modules/open_zfs/osv/module/os/osv/zfs/zfs_vnops_os.c :: zfs_vop_cache()
  borrows the ARC dbuf page zero-copy:
    dmu_object_info() record-size check -> dmu_buf_hold(os, z_id, uio_offset,
    arc_page_tag, &db, DMU_READ_PREFETCH) -> if IS_P2ALIGNED(db_data,PAGE_SIZE)
    && page fully backed: osv_pagecache_map_arc_page(key, db, db_data+intra_off)
    (the page-cache page ALIASES the ARC buffer; hold transfers to the cache).
    Else falls back to alloc-page + zfs_read copy (drops the hold first).
- zfs_initialize_osv.c registers osv_arc_dbuf_rele (= dmu_buf_rele) via
  osv_pagecache_register_arc_rele at init.
- loader.elf exports osv_pagecache_map_arc_page + osv_pagecache_register_arc_rele
  (T); libsolaris.so has osv_arc_dbuf_rele + zfs_vop_cache. Verified by nm.

Nothing to write. My deliverable is the correctness/lifetime AUDIT + on-metal
VALIDATION + an honest measurement of what the borrow actually buys.

## 2. LIFETIME COUPLING (the flagged risk) - SOUND by construction + PROVEN.

The borrow page (cached_page_arc_borrow, core/pagecache.cc) lives in read_cache;
its dtor calls dmu_buf_rele. read_cache pages are deleted ONLY via paths that
tear down ALL PTE mappings BEFORE delete cp:
  - remove_read_mapping: delete only when cp->unmap() hits 0 remaining mappings.
  - drop_read_cached_page: cp->flush() clears every PTE, then delete.
read_cache has NO independent LRU/size-cap eviction (only write_cache + the
BSD arc_read_cache have that; the access_scanner never touches read_cache). So
NO path frees a borrow page while live-mapped, and NO path drops the hold early.
The dbuf hold outlives every mapping of its page. UAF/early-free impossible.
PROVEN: 20 mmap/munmap cycles of a 512M/8K file = 20 x 131072 = ~2.6M dbuf
hold/rele pairs, 0 crash / 0 assert / rc=0.

## 3. abd LINEAR vs SCATTER - handled correctly by the alignment guard.

dbuf.db_data == the ARC buf b_data (dbuf.c). In arc_buf_alloc_impl (arc.c) a buf
shares the hdr pabd ONLY when abd_is_linear && !linear_page; else b_data =
arc_get_data_buf() = a fresh CONTIGUOUS linear buffer. So db_data is ALWAYS
contiguous (never a scatter list). IS_P2ALIGNED(db_data,PAGE_SIZE) is the correct
gate. Measured: at recsize 512/4K/8K/128K/1M the borrow engaged 100%, align_fail=0,
data byte-correct every time.

## 4. BUILD + READ-CORRECTNESS (the gate).

conf_zfs=openzfs fs=zfs image=empty built rc=0 (fedora:41, gcc 14.3.1, ld 2.43).
Booted, created+mounted a ZFS pool IN-GUEST on a raw NVMe (zpool create ok,
recordsize set, 0 CKSUM errors), read+checksummed a 512M patterned file through
mmap: mmapverify_ok=1 (aliased read BYTE-IDENTICAL to the written pattern),
cksum stable 38687713547bcc26 across runs.

Instrumented counter (temporary, NOT shipped): 512M/8K mmap fault ->
  VOPCACHE_DBG calls=131072 borrow=131072 copy=0  => borrow engages on 100% of
  faults; the forced-copy leg (noborrow=1) -> borrow=0 copy=131072, also ok=1.

## 5. WHAT THE BORROW ACTUALLY BUYS (honest, measured borrow-vs-copy A/B).

Same 512M/8K file, mmap read-fault, borrow vs forced-copy on the SAME build:
  mmapread throughput: borrow 1385 MB/s vs copy 798 MB/s  => +74% (eliminates the
    per-page osv_alloc_page + zfs_read + memcpy).
  free-page delta: borrow ~516 MB vs copy ~522 MB  => RAM-NEUTRAL within OpenZFS.

CORRECTION to the design's premise: the ~501MB "double-buffer" in
PERF-osv-openzfs.md is the BSD-vs-OpenZFS gap, NOT a borrow-vs-copy gap inside
OpenZFS. On OSv, OpenZFS's ARC pins the dbuf resident (one copy) whether or not
the page is borrowed; the copy path's extra page is transient/reclaimable and
_SC_AVPHYS_PAGES does not durably show it. The borrow's real, measured win is
CPU/throughput on the mmap fault path (+74%), not the ~100x RAM reduction BSD
gets from its fundamentally different unified ARC/page-cache accounting. Reaching
BSD's ~5MB would require OpenZFS ARC accounting changes far beyond this shim.

## 6. WHY THIS DOES NOT MOVE THE pgbench RO NUMBER (the parity gap).

The borrow ONLY affects the mmap read-FAULT path (zfs_vop_cache). PostgreSQL
reads relation data via pread(), which takes vfs_file::read -> VOP_READ ->
zfs_read directly and NEVER calls zfs_vop_cache. Confirmed: seqread_warm (read()
path) produced ZERO VOPCACHE_DBG calls. So the ARC borrow helps mmap-heavy
consumers (dynamic linker, mmap'd DBs, large indexes) but does NOT touch PG's
pread hot path, and therefore does NOT climb the pgbench RO 0.25x plateau. That
plateau is the process-per-connection wake floor (WAKE-INLINE-RESULT.md), a
separate structural cost, not the read-path copy.

The one read-path lever that WOULD help concurrent pread on a shared hot file is
the SECONDARY item: dropping the redundant per-vnode v_lock for VREG ZFS pread
(FOF_OFFSET), mirroring the VBLK fast path (c063c5c58 in vfs_fops.cc). ZFS's own
RL_READER rangelock makes the outer exclusive v_lock redundant on reads. NOT
done this run: it is a shared-VFS-path change (must be scoped VREG+FOF_OFFSET so
it cannot perturb non-ZFS FS), and it carries the issue-#504 deadlock history;
needs its own crash-gate + deadlock validation. Banked as the next lever.

## 7. DELIVERABLE PUBLISHED.

gh-fork wip/pg-zfs-readpath @ 7823a2199: zfs-bench mmapverify workload (the
read-correctness + zero-copy validation tool used above). G-signed, leak-clean,
off upstream/master 0e34e4dc2, em-dash-free. The borrow WIRING itself needs no
new commit (already on master).
