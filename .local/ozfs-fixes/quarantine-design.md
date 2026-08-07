# UAF-quarantine catcher design (ready to implement) — for the ZFS metadata corruptor
From agent 79a5dc30 (designed, not yet coded). LAYOUT-NEUTRAL (no object size change).

TARGET: identity-heap UAF/backward-overflow of a ZFS-write-path kmem_cache object
(abd_chunk, dbuf, arc_buf_hdr, dbuf_dirty_record) that clobbers ~128KiB metadata,
SMP race, recordsize=8k. (arena-DMA, forward-overflow, magazine, per-CPU-COW all ruled out.)

DESIGN (in the OSv kmem_cache free path — bsd/sys/cddl/compat/opensolaris kmem shim,
or wherever kmem_cache_free routes for the ZFS caches):
- Fixed ring of N slots (e.g. N=4096) per targeted cache set, in IDENTITY-heap static array (never COW).
- On kmem_cache_free(obj): run the destructor, then INSTEAD of free(): poison the WHOLE usable
  object (use malloc_usable_size(obj) — poison entire usable size, not just kc_size -> also catches
  backward-overflow from the NEXT object) with a per-slot pattern, enqueue on the ring.
- When ring full: evict oldest -> VERIFY its poison intact -> if intact real free(); if MISMATCH ->
  the object was written AFTER free = UAF (or a neighbor backward-overflowed into it). DUMP: cache name,
  obj addr, first mismatch offset, expected-vs-found 32 bytes, and the freeing backtrace (stored at free).
- Detection latency = ring depth; deeper ring = more likely still-quarantined when the stale write lands.
- Gate behind #ifndef WALL3_QUAR / #define 0, layout-neutral, CONF_fork.
IMPLEMENT verbatim; spend budget on code->build->run->catch, not re-design.
