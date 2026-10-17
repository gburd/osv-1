# T2: ext4 (libext/lwext4) durability + perf gaps -- do D2.1/D2.2 matter? (read-only audit)

Copyright (c) 2026 Greg Burd. BSD-3-Clause.

Scope: read-only. Evidence read on branch `integ/pg-master` (contains `upstream/master`
442d258b and the real-fsync commit `af27ba4b7`; verified `git merge-base --is-ancestor`).
Anchors in the task were re-read, not re-found.

## (a) ext4's role in our deployment: READ/boot/compat, NOT the durable PG store

The headline durable workload is PostgreSQL, and PG runs on **OpenZFS**, which the roadmap
calls "the keystone" (ROADMAP.md:31-42 ARC<->pagecache zero-copy bridge; CLEAN-BASE-RESOLVED.md
confirms the PG-on-ZFS stack). ext4 appears only as a benchmark comparison arm and a
general-purpose/boot/seed FS:

- The libext README shows the intended use: seed a disk on the host, boot OSv, `--mount-fs=ext,...`
  for read/compat (modules/libext/README.md). No "PG data dir on ext4" guidance anywhere.
- ext4 was run as a PG data-store arm ONCE, in the multi-FS benchmark (ROADMAP.md:3013-3238), and
  the verdict was explicit: "**OSv ZFS is the viable FS for PG**" (ROADMAP.md:3215). The ext4-for-PG
  arm was a measurement, not a deployment target.
- The one "ext4 unusable for PG" scare (ROADMAP.md:3195-3215) was **retracted**: it was an OSv
  base-staleness bug, not ext4. On the stale branch `ext_fsync` was `vop_nullop`, so `fsync(2)` was
  a no-op and PG never flushed lwext4's write-back cache (BASE-IS-BEHIND-MASTER.md:*,
  lwext4-durability-bug-DRAFT.md "DO NOT FILE THIS REPORT. IT IS WRONG."). A C reproducer against
  lwext4 6f6d8f7c with OSv's exact config PASSES clean-unmount, crash-after-fsync, and the 200-file
  CREATE DATABASE shape. `integ/pg-master` has af27ba4b7, so `ext_fsync` is now real
  (ext_vnops.cc:1055-1068 -> `ext4_block_cache_flush`).

**Consequence: ZFS carries all durable PG writes. ext4's job is boot image / read / compat / a
benchmark baseline. D2.1 and D2.2 are therefore LOW priority for the current roadmap.**

## (b) D2.1 journaling: crash-consistency gap + wiring size

Today ext4 on OSv runs with **no journal at all**, two layers deep:
1. The library journal is compiled OFF -- the pin 6f6d8f7c5 is literally "Disable journaling"
   (confirmed in modules/lwext4/Makefile `lwext4_commit?=6f6d8f7c...`).
2. The OSv layer never calls it -- "The libext does not implement journal" (ext_vnops.cc:19);
   grep for `journal|jbd|trans_start` in ext_vnops.cc returns only that comment line, and
   ext_vfsops.cc has **no recovery/replay/orphan handling at all** (grep confirmed).

Crash-consistency story = **no-journal (worse than ext4 "data=ordered"; closer to a non-journalled
ext2)**. `ext_internal_write` (ext_vnops.cc:784-945) writes data blocks and mutates inode/bitmap/
extent metadata through the write-back block cache with no ordering barrier; durability happens only
when `fsync`/`sync`/unmount flush the whole device cache (ext_vnops.cc:1055, ext_vfsops.cc:243).
On an **unclean shutdown** (no fsync, or a crash mid-flush) you can get: a torn inode-vs-block state
(size updated but blocks not written, or vice versa), stale bitmaps, and **leaked orphan inodes** --
the delete-on-last-close list `inodes_to_delete` is in-memory only and is drained at *unmount*
(`ext_delete_outstanding_inodes`, ext_vnops.cc:300-315), so a crash loses it with no on-disk orphan
list to recover from. There is no `e2fsck`-equivalent on mount, so a dirty image is mounted as-is.

- **Acceptable for a read/boot/seed image** (written once on the host with a real Linux ext4+journal,
  then mounted read-mostly on OSv): yes.
- **Not acceptable for a durable store under crash:** correct -- which is exactly why PG is on ZFS.

Rough wiring size if we ever do it (OSv side, the part no fork gives us for free, per
ANTIMATTER-LWEXT4-EVAL-2026-10-16.md:43-51): re-pin to a journal-enabled lwext4 build (drop
`-DJOURNALING off`), then in modules/libext: (1) call `ext4_recover` on mount in `ext_mount`
(ext_vfsops.cc:141-217); (2) wrap the metadata-mutating ops in `ext4_journal_start/stop` --
`ext_write`/`ext_internal_write`, `ext_create`/`ext_mkdir`/`ext_remove`/`ext_rename`,
`ext_truncate` (the alloc path ~1390), `ext_setattr`, and the delete paths (`ext_close`,
`ext_delete_outstanding_inodes`); (3) make `ext_fsync`/`ext_sync` commit the transaction, not just
flush the cache; (4) a `conf` toggle to keep it optional. Call it a **medium** OSv-side task
(~8-12 functions in ext_vnops.cc + mount/toggle), plus the re-pin PR and a crash/recovery test
suite. antimatter-studios/lwext4 hardens the *library* journal (de-risks it) but writes **none** of
the OSv wiring (eval:43-51).

## (c) D2.2 perf: naive alloc + missing pagecache bridge + what #1510 already covers

**Naive eager allocation (ext_vnops.cc:1390).** The TODO is in `ext_truncate`'s *grow* path: to
extend a file it `alloc_contiguous_aligned(extra_size)`, `memset`s it to zero, and writes the whole
range (ext_vnops.cc:1393-1408). It is naive in three ways named in the comment: no sparse-file
support, no reserve-blocks-read-zero trick, and a full-size bounce buffer. The normal write path
(`ext_internal_write`) also has **no delayed allocation** -- it appends blocks inline per write
(`ext4_fs_append_inode_dblk`), so it cannot batch/coalesce extents the way Linux ext4 delalloc does.
Impact is bounded: it hurts large truncate-grow / `posix_fallocate`-shaped and append-heavy
patterns, and wastes a transient full-size allocation; it is **not** on the hot path for the
read-mostly boot/seed role. Fix size: **small-medium** (sparse/reserved-block handling in the grow
path + optional delalloc batching), but only worth it if ext4 becomes a write target.

**Missing zero-copy pagecache bridge (ext_vnops.cc:1934-1960).** `ext_map_cached_page` warms the
shared page cache by **allocate-and-copy** (OWNED page handed to `map_owned_read_cached_page`), not a
borrow-and-pin. The comment says a borrow-and-pin bridge "like the ZFS ARC one can come later if it
shows up hot" (ext_vnops.cc:1953). Reusing the ZFS ARC bridge pattern (ROADMAP.md:941-957: the
borrow infra `cached_page_arc_borrow`/`osv_pagecache_map_arc_page` exists and IS wired for ZFS mmap)
would buy zero-copy mmap-fault reads on ext files. **But note the ZFS lesson (ROADMAP.md:957):** the
ARC borrow path *only* affects the **mmap fault path**; PG reads via `pread`, which never calls
`vop_cache`, so the bridge did **not** move PG's RO plateau. For ext4 the bridge would help only
mmap/exec-image read workloads, not PG. Fix size: **medium**, same shape as the ZFS shim, low payoff
given the role.

**#1510 already covers the read side of D2.2** (verified `gh pr view 1510`, DRAFT/OPEN): it adds
read/write-into-user-buffer (skip bounce copy), a sequential read-ahead cache, async double-buffered
prefetch, and a multi-window prefetch ring tuned N=4/M=4 to a ~1.28 GB/s knee. It is explicitly
built on af27ba4b7 and reports ext4 sequential reads were ~33% of Linux (the per-`read()`
round-trip), **writes already at parity**, random reads ~86%. So: the **sequential-read** half of
D2.2 is designed and coded (pending a fresh re-measure to un-draft); the **write-alloc** and
**zero-copy-mmap** halves remain unaddressed, and the write path is already near parity.

Cross-ref other open ext4 PRs (all OPEN/MERGEABLE, non-draft): #1449 (readlink/readdir heap-overflow,
security), #1533 (extent-header + superblock validation), #1500 (pin lwext4 to 6f6d8f7c). These are
correctness/security/reproducibility, not D2 perf/durability.

## (d) RECOMMENDATION

**DEFER D2.1 and D2.2 (except finishing #1510).** Gating condition: do them only **if** a target
workload is chosen to write durably to ext4 *and* cannot use ZFS (e.g. a customer image mandating
ext4-on-OSv as its data store, or an ext4-on-OSv write benchmark we commit to publishing). Until
then:

- **D2.1 (journal):** DEFER. The no-journal gap is real but only matters for a durable ext4 store,
  which we do not have -- PG is on ZFS. Keep the ANTIMATTER plan (eval:60-80): curate hardened lwext4
  journal fixes as reviewed patches now; re-pin + wire JBD only when D2.1 is actually commissioned.
- **D2.2 (perf):** mostly DEFER, with ONE live item -- **finish #1510** (re-measure on current
  master, un-draft). That lands the sequential-read win cheaply and is already written. The
  write-alloc (ext_vnops.cc:1390) and zero-copy-mmap bridge (ext_vnops.cc:1953) stay deferred: write
  is near parity and the mmap bridge misses PG's `pread` path anyway (ROADMAP.md:957).

---

### 3-line recommendation summary
1. ext4 is a read/boot/seed/compat FS and a benchmark arm; ZFS is the keystone and carries all
   durable PG writes -- so D2.1 and D2.2 are low priority.
2. DEFER D2.1 (no-journal, crash-unsafe only matters for a durable ext4 store we don't have;
   OSv-side wiring is a medium ~8-12-function job) and DEFER the D2.2 write-alloc + zero-copy-mmap
   bridge; the one thing worth finishing is **#1510** (sequential-read, already coded, re-measure to
   un-draft).
3. Gate reopening D2.1/D2.2 on: a workload chosen to write durably to ext4 that cannot use ZFS.
