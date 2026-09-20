> # DO NOT FILE THIS REPORT. IT IS WRONG.
>
> **Status: SUPERSEDED / WITHDRAWN (2026-09-05, maintenance sweep round 4).**
>
> A self-contained C reproducer was written against the actual
> osvunikernel/lwext4 fork tip (6f6d8f7) using OSv's exact build config, and it
> **does not reproduce**. lwext4 durably persists newly created files and
> directories in all three tested shapes: clean unmount, crash-after-fsync (no
> unmount), and the 200-file `CREATE DATABASE` shape under block-cache pressure.
> All cases PASS. Reproducer + results: `.local/lwext4-repro/`.
>
> **The actual root cause was OSv base staleness, not an lwext4 bug.** The
> PostgreSQL failure below was observed on `wip/aarch64-forkcow-signed`, which
> does not contain upstream `af27ba4b7` ("libext: real fsync + page-cache bridge
> for ext2/3/4", merged 2026-08-07). On that branch `ext_fsync` is literally
> `((vnop_fsync_t)vop_nullop)`, so `fsync(2)` on ext4 was a **no-op** and
> PostgreSQL never flushed lwext4's write-back block cache. lwext4 was never
> asked to make anything durable. Current `upstream/master` implements
> `ext_fsync` via `ext4_block_cache_flush`, which is precisely the barrier the
> reproducer proves lwext4 honors.
>
> Filing this would be a false bug report against a third-party project, blaming
> a dormant upstream for our own stale base.
>
> **Before making any ext4-on-OSv durability claim:** retest ext4-on-arm for
> PostgreSQL on a base containing `af27ba4b7`. The "ext4 is unusable for
> PostgreSQL" conclusion recorded in `.local/ROADMAP.md` and
> `.local/pg-osv-milestones.md` is unsupported and probably wrong; it needs to be
> re-measured, and corrected if the retest passes.
>
> The text below is preserved verbatim only as the historical record of what was
> believed before the reproducer existed. Every root-cause hypothesis in it is
> unverified and case B of the reproducer contradicts the central claim.

---

# lwext4 does not durably persist newly created files/directories (fsync of a fresh inode leaves it unreadable after remount)

## Summary

When a file or directory is **created** on a mounted lwext4 filesystem and then
`fsync`/flushed, the new inode and/or its parent directory entry is not durably
written to the block device. After a clean unmount+remount (or a fresh mount of
the same device image), the just-created path is gone: the directory entry, the
inode, or the newly allocated data blocks are missing, and opening the path
returns `ENOENT`.

Reading and rewriting **pre-existing** files (files that were present at mkfs /
seed time) works and persists correctly. The bug is specific to the durability
of **newly allocated** metadata (inodes, directory entries, and the block-group
allocation bitmaps that back them).

## Impact

This makes lwext4 unusable as a read-write filesystem for any workload that
creates files at runtime and expects them to survive a remount or a crash. It
was found while running PostgreSQL on an ext4 volume: `CREATE DATABASE`
allocates a new `base/<oid>/` directory tree, the operation appears to succeed,
but a subsequent checkpoint fails with:

```
could not open file "base/16395/112": No such file or directory
```

on a file the same process created moments earlier. The created directory tree
(`base/<oid>`) is not durably present.

## Reproduction (minimal, filesystem-only)

Using the lwext4 API directly (no application layer), against a freshly mkfs'd
image:

1. `ext4_mount()` a clean image, `ext4_journal_start()` if journaling is enabled.
2. Create a directory: `ext4_dir_mk("/base")` then `ext4_dir_mk("/base/16395")`.
3. Create and write a file inside it:
   `ext4_fopen("/base/16395/112", "wb")`, `ext4_fwrite(...)`, `ext4_fclose()`.
4. Flush/sync: `ext4_cache_flush("/")` (and/or `ext4_journal_stop()` +
   `ext4_umount()`).
5. Re-`ext4_mount()` the same image.
6. `ext4_fopen("/base/16395/112", "rb")` -> returns an error; the path resolves
   `ENOENT`. Depending on ordering, sometimes the leaf file is missing, sometimes
   the whole `/base/16395` directory is missing.

Expected: after step 4 the created directory and file are durable, so step 6
opens the file and reads back what was written in step 3.

Observed: the newly created path is not present after remount.

## What appears to be wrong

The newly dirtied blocks that back a fresh allocation are not all making it to
disk on flush/unmount. Candidate sources (in rough order of suspicion):

1. **Block-cache flush does not cover all metadata dirtied by an allocation.**
   Creating a file dirties several distinct blocks: the target inode block, the
   parent-directory data block(s) that hold the new dirent, the inode bitmap, the
   block bitmap, and the group-descriptor/superblock free counts. If
   `ext4_cache_flush()` / the writeback path only flushes a subset of these (for
   example the file's own inode+data but not the parent-directory block or the
   allocation bitmaps), the inode exists on disk but is unreachable, or the
   dirent points at an inode the bitmap still marks free and a later mount treats
   as unallocated.

2. **Journal (JBD) does not replay newly created metadata on the next mount.**
   If journaling is enabled, the create transaction may be committed to the
   journal but not checkpointed to its final location, and the replay on remount
   may not be applying it. (This may be related to the known JBD replay issues in
   issue #86.)

3. **Directory-entry write is buffered in a block that is dropped, not flushed,**
   when the parent directory's inode is evicted from the block cache before the
   flush walks it.

## Environment

- lwext4 fork tip built into OSv (osvunikernel/lwext4), used via OSv's `libext`
  VFS glue. The same durability failure signature (`ENOENT` on a just-created
  file after it was fsync'd) is reproducible at the PostgreSQL layer and points
  squarely at the create+fsync path, not at the VFS glue (reads of pre-existing
  files, and rewrites of pre-existing files, are durable; only newly created
  paths are lost).
- Block device is a plain image over a virtio-blk disk; no partition offset
  tricks. Mounted read-write.

## Ask

Is durable persistence of newly created inodes/dirents (create -> fsync ->
remount -> file still present) expected to work on the current fork/master, with
and without journaling? If so, this is a bug in the flush/writeback coverage of
allocation metadata (or in JBD checkpoint/replay). If a specific
`ext4_cache_flush` / `ext4_journal_stop` ordering is required to make a create
durable, documenting that ordering would also resolve this for us.

I am happy to provide a self-contained C reproducer against the lwext4 API and
the exact block-level diff (which blocks are dirty at flush time vs which landed
on disk) if that helps localize it.
