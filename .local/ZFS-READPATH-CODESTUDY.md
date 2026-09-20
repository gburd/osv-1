# ZFS RO read-path code study - the ARC<->page-cache zero-copy bridge (LOCAL, no EC2)

Copyright (C) 2026 Greg Burd

GOAL: OSv OpenZFS RO read is ~0.34x Linux at c8 and FLAT ~25k tps c8..c64 (Linux climbs to
~140k). This is the CODE-side study. The ALREADY-MEASURED root cause (PERF-osv-openzfs.md) is the
MISSING ARC<->page-cache zero-copy bridge that BSD-ZFS on OSv has and the OpenZFS port does not.
This doc: (1) the exact BSD bridge mechanism (the reference to port), (2) the exact OpenZFS copy
points, (3) a concrete shim design to make an OSv page-cache page alias the OpenZFS ARC/dbuf
buffer, and (4) a secondary VFS-lock serialization finding. This shim is the KEYSTONE read fix.

## Measured evidence (PERF-osv-openzfs.md, already run)
- Warm sequential read: BSD 8510 MB/s vs OpenZFS 3446 MB/s (BSD +147%).
- Random 4k read QD1: BSD 230326 IOPS vs OpenZFS 35338 IOPS (BSD +552%).
- mmap 512M free-page delta (the diagnostic): BSD +5 MB vs OpenZFS +501 MB (BSD ~100x less RAM =
  OpenZFS double-buffers the entire working set: one copy in the private ARC, one copy in a
  page-cache page).
=> OpenZFS-on-OSv pays a per-read COPY + a second resident copy; BSD-ZFS ALIASES the ARC buffer as
   the page-cache/mmap page (zero-copy, single resident copy). That per-op copy cost is the ~25k
   RO tps ceiling; it does not scale, so the curve is flat.

## (1) THE BSD-ZFS REFERENCE BRIDGE (the mechanism to port)

Files: core/pagecache.cc, fs/zfs/zfs_initialize.c, bsd/porting/mmu.cc,
bsd/.../fs/zfs/arc.c (arc_share_buf/arc_unshare_buf/arc_buf_get_hashkey/arc_buf_accessed).

How a BSD-ZFS page fault becomes zero-copy:
1. Routing: BSD-ZFS tags its fsid with ZFS_ID, so `IS_ZFS(st.st_dev)` is TRUE
   (core/pagecache.cc:37-38 comment). That selects the ARC-bridge branches in
   `pagecache::get()` (core/pagecache.cc ~line 45+).
2. On a read fault miss, `get()` (the `IS_ZFS` branch) calls `create_read_cached_page` ->
   `fp->read_page_from_cache` -> VOP_CACHE. BSD's VOP_CACHE path (via bsd/porting/mmu.cc:62)
   calls **`pagecache::map_arc_buf(key, arc_buf_t* ab, page)`** (core/pagecache.cc:495).
3. `map_arc_buf` builds a **`cached_page_arc`** (core/pagecache.cc:304) that HOLDS the
   `arc_buf_t*` and calls **`arc_share_buf(ab)`** (bsd/.../arc.c:1481), which sets
   `hdr->b_mmaped = 1` - marking the ARC header as shared-in-place so the ARC will NOT evict/free
   it out from under the mapping. The page the mapping points at IS the ARC buffer's `b_data`,
   NOT a copy.
4. `get()` then `write_pte(cp->addr(), ptep, pte_mark_cow(...))` - maps the ARC buffer page
   directly into the faulting VA, COW-marked. ZERO copy. Multiple mappers of the same
   (spa,dva,birth) share the ONE ARC buffer (that key is `arc_buf_get_hashkey`, arc.c:1498).
5. Lifetime: when the last mapping drops, `~cached_page_arc` calls `arc_unshare_buf` (b_mmaped=0)
   so the ARC can reclaim it. `unmap_arc_buf` (arc.c-side eviction callback ->
   pagecache.cc:488) tears down all mappings + `flush_tlb_all()` when the ARC evicts a shared buf.
6. LRU feedback: the access scanner calls `arc_buf_accessed(hashkey)` (arc.c:1508) so shared
   pages still feed the ARC's LRU (clears the accessed bit) - the ARC ages them correctly even
   though they live as page-cache mappings.

KEY BSD PROPERTY that makes this possible: BSD-ZFS's `arc_share_buf` is a PUBLIC function and the
ARC buffer's `b_data` is a plain contiguous page the mmu can map. The bridge is just "pin the ARC
buf (b_mmaped), hand its b_data page to the pagecache, unpin on last unmap."

## (2) WHERE OPENZFS COPIES INSTEAD (the exact points)

Routing: the OpenZFS port DELIBERATELY does NOT tag ZFS_ID
(external/openzfs/module/os/osv/zfs/zfs_vfsops.c; core/pagecache.cc:32-35 comment), so
`IS_ZFS()` is FALSE and OpenZFS files take the plain `read_cache` path, NOT the ARC bridge. WHY:
OpenZFS 2.x made `arc_share_buf()` STATIC/internal (core/pagecache.cc:552-554), so the BSD bridge
(map_arc_buf / cached_page_arc / arc_share_buf_fun) CANNOT hook an OpenZFS ARC buffer - the public
entry point the BSD bridge needs no longer exists in OpenZFS 2.x.

Copy point A - the plain read() path (THE PG HOT PATH; pgbench SELECT reads via pread):
  zfs_vop_read (zfs_vnops_os.c) -> zfs_read (external/openzfs/module/zfs/zfs_vnops.c:329) ->
  `dmu_read_uio_dbuf(...)` (zfs_vnops.c:463/520) which copies dbuf/ARC bytes into the uio, then
  `zfs_uiomove` -> **`uiomove` (fs/vfs/subr_uio.cc:59) = a plain memcpy** into PG's buffer. One
  copy from the ARC dbuf into the caller buffer on EVERY read. (Same shape as BSD read(), so
  read() was never the BSD win; but OpenZFS ALSO pays copy B below for any mmap/second reader.)

Copy point B - the mmap fault path (the double-buffer the 501MB delta measures):
  pagecache::get() (read_cache branch) -> create_read_cached_page -> VOP_CACHE ->
  **`zfs_vop_cache` (zfs_vnops_os.c:1197)**: it `osv_alloc_page()`s a FRESH page (line 1214),
  calls `zfs_read` to COPY the ARC data into that fresh page, then
  `osv_pagecache_map_page` (line 1240) inserts the COPY into read_cache. So the working set now
  lives TWICE: once in the OpenZFS private ARC, once as the fresh read_cache page. That is the
  +501MB vs BSD +5MB.

## (3) THE SHIM DESIGN - make an OpenZFS read_cache page ALIAS the ARC/dbuf buffer (KEYSTONE)

GOOD NEWS: the borrow half of the shim is ALREADY BUILT in the pagecache but NEVER WIRED from the
OpenZFS side. core/pagecache.cc:564-598 defines `cached_page_arc_borrow` +
`osv_pagecache_map_arc_page(key, db, page)` + `osv_pagecache_register_arc_rele(rele)`: a
read_cache page that is BORROWED from a pinned dbuf (page NOT owned/freed by the cache; the dbuf
hold is released via a registered `arc_dbuf_rele` callback when the cached page is dropped). This
is exactly the OpenZFS analog of BSD's cached_page_arc/arc_share_buf. It coexists with the BSD
path (different cache, different libsolaris build). It is present, compiled, and UNUSED - the
OpenZFS `zfs_vop_cache` still calls the COPY path `osv_pagecache_map_page`, never the borrow path
`osv_pagecache_map_arc_page`.

THE SHIM = 3 pieces, from most to least valuable:

  (S1) Wire mmap zero-copy (small, unblocks the 501MB double-buffer): rewrite `zfs_vop_cache`
       (zfs_vnops_os.c:1197) to, instead of alloc-page + zfs_read-copy + osv_pagecache_map_page:
       - get the dbuf for the faulting (znode, offset): `dmu_buf_hold_array` /
         `dbuf_hold` on zp's object at the page-aligned offset (the ARC-backed db_data is a
         contiguous, decompressed buffer for the record; for recordsize>=PAGE_SIZE a page maps a
         sub-range of one db_data).
       - PIN it (dbuf hold keeps db_data resident) and pass `db_data + page_off` as the page to
         `osv_pagecache_map_arc_page(key, db, page)`.
       - register `arc_dbuf_rele` once at init to `dmu_buf_rele(db, tag)` so dropping the
         read_cache page releases the dbuf hold.
       Result: the mmap fault maps the ARC dbuf buffer IN PLACE, COW-marked, zero-copy, single
       resident copy - the OpenZFS equivalent of BSD's arc_share_buf. Constraints: the dbuf's
       db_data must be page-aligned + >= PAGE_SIZE per mapped page. OpenZFS ARC data buffers are
       allocated from the abd/linear path; a LINEAR abd (abd_os.c) is a single contiguous
       allocation whose base is page-suitable for recordsize>=4K (ashift=12, recordsize=8K in the
       PG config - each 8K record is one 2-page contiguous db_data). For SCATTER abd or
       recordsize<PAGE_SIZE, fall back to the copy path (correctness first).

  (S2) Serve read() from the borrowed page zero-copy (the PG hot path win): the plain read()
       currently always `dmu_read_uio_dbuf`-copies. There is already `osv_pagecache_read_page`
       (pagecache.cc:626) that copies a cached read_cache page into a buffer - still a copy, but
       from the borrowed ARC page. TRUE zero-copy for read() is not achievable through the POSIX
       read() contract (read() copies into a user buffer by definition), so read() will always
       pay ONE copy (ARC db_data -> user buffer) on both BSD and OpenZFS. The BSD read() win in
       the microbench came from serving the copy directly out of the shared ARC page (one memcpy)
       vs OpenZFS's ARC-lookup + borrow-accounting + copy. So for read(): the win is not
       "eliminate the copy" but "make the ARC lookup + copy as cheap as BSD's": have `zfs_read`
       hit the ALREADY-DECOMPRESSED, ALREADY-HELD dbuf's db_data (which `dmu_read_uio_dbuf`
       already does via sa_get_db) and memcpy once - it already does this; the OpenZFS 35k-IOPS
       cap is the per-op ARC hash + dbuf hold + abd bookkeeping, not a second copy. So S2's payoff
       is smaller than S1's for read(); S1 (mmap/double-buffer) is where the measured 100x-RAM and
       the warm-read 2.5x live.

  (S3) LRU feedback: register an OpenZFS analog of `arc_buf_accessed` so borrowed pages age in the
       ARC LRU (else a long-lived mapping pins a dbuf the ARC thinks is cold). OpenZFS: touch the
       dbuf (dbuf_hold/rele cycle marks it accessed) from the access scanner. Minor; needed for
       correctness under memory pressure, not for the throughput number.

PRIORITY: S1 first (wire the existing, already-built borrow path from zfs_vop_cache = the smallest
diff, kills the 501MB double-buffer and the warm-read/mmap gap). S3 with it (pin-safety under
pressure). S2 is a smaller, separate per-op optimization.

## (4) SECONDARY - the OSv VFS per-vnode exclusive lock serializes same-file reads
`fs/vfs/vfs_fops.cc:64` holds `vn_lock(vp)` (an EXCLUSIVE `mutex_lock(&vp->v_lock)`,
fs/vfs/vfs_vnode.cc:147) across the whole VOP_READ for VREG files (a VBLK+FOF_OFFSET fast path
exists, c063c5c58, but VREG/ZFS does not get it). In OSv's single-AS unikernel every forked PG
backend reading the SAME hot file (pgbench_accounts + its PK index) shares ONE vnode -> ONE v_lock
-> reads FULLY SERIALIZED across zfs_read (ARC lookup + copy). This ALSO produces a flat plateau
under rising concurrency and compounds the copy cost: even after the shim makes each read cheaper,
v_lock caps concurrency at 1 per hot file. HISTORY: b5eadc37f removed exactly this lock for ZFS in
2014 ("prevents parallel ZFS reads on the same file, performs terribly bad vs FreeBSD"); reverted
697943f63 for an issue-#504 deadlock in the OLD ARC-bridge path. The modern read_cache path +
ZFS's own per-znode RL_READER rangelock (zfs_vnops.c:390, already shared for reads) make the outer
v_lock redundant. FIX: mirror the VBLK fast path - drop v_lock around VOP_READ for VREG on ZFS
(keep it for the mmap read_page_from_cache entry, a different path). Validate against the #504
deadlock (should not apply: no ARC-bridge re-entry on the read_cache path) + the fork/COW crash
gate.

## Guidance to the metal profiler (priority)
1. Confirm the double-buffer: RSS/free-page delta on OpenZFS PG under RO load (expect ~working-set
   x2 resident) - the S1 target.
2. RIP/time in `dmu_read_uio_dbuf` + `memcpy`/`abd_copy` at c8 (the per-op copy cost = the ~25k
   ceiling per backend).
3. Lock-profile v_lock on the hot table vnode at c32 (the flat-plateau serializer, item 4).
4. After S1 (wire the borrow path) + item-4 lock drop: re-run RO c8..c64, expect warm-read/mmap to
   jump toward BSD and the plateau to start climbing.

## The two levers, ranked by value
- KEYSTONE: S1 - wire the ALREADY-BUILT `osv_pagecache_map_arc_page` borrow path from
  `zfs_vop_cache` so OpenZFS mmap/page-cache aliases the ARC dbuf in place (kills the +501MB
  double-buffer + the 2.5x warm-read gap). Smallest diff for the biggest measured gap.
- COMPOUNDING: item-4 - drop the redundant per-vnode v_lock for VREG ZFS reads (mirror the VBLK
  fast path) so N backends read the same hot file concurrently instead of serialized.
