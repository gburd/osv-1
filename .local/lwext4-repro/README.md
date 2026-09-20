# lwext4 create-durability reproducer

Local-only (untracked). Written 2026-09-05 during maintenance sweep round 4 to
settle whether `.local/lwext4-durability-bug-DRAFT.md` describes a real lwext4
bug worth filing upstream.

## Verdict

**ALL CASES PASS.** lwext4 durably persists newly created files and directories.
The draft bug report must NOT be filed.

## What it tests

`lwext4-create-durability.c` drives the lwext4 API directly (no OSv, no VFS, no
PostgreSQL) against a freshly `ext4_mkfs`'d 64 MB image on the Linux `file_dev`
blockdev, built with the exact config the OSv consumer uses
(`CONFIG_JOURNALING_ENABLE=0`, `CONFIG_BLOCK_DEV_CACHE_SIZE=16`, dynamic bcache,
`ext4_cache_write_back(1)` at mount, matching `modules/libext/ext_vfsops.cc`).

Three cases, each mirroring a claim in the draft:

- **A. clean unmount.** mkdir `/base`, mkdir `/base/16395`, create+write
  `/base/16395/112`, `ext4_cache_flush` (the fsync barrier), clean umount,
  remount, expect the file present with its payload intact.
- **B. crash after fsync.** Same, but drop in-core state WITHOUT unmounting,
  then mount the image again. This is the guarantee `fsync(2)` actually owes:
  durability without a clean unmount.
- **C. `CREATE DATABASE` shape.** 200 files in one directory (more than the
  16-block cache holds, so allocation metadata must be written back under cache
  pressure), flush, then verify every file both in the live mount and after a
  clean umount+remount.

## Result (against osvunikernel/lwext4 tip 6f6d8f7, 2025-07-04)

```
case A: create + flush + CLEAN umount + remount     all PASS
case B: create + flush, NO umount (crash), then mount  all PASS
case C: CREATE DATABASE shape (200 files)           all PASS

no failure (0 failures)
```

## Conclusion: the failure was OSv base staleness, not lwext4

The PostgreSQL symptom in the draft

```
could not open file "base/16395/112": No such file or directory
```

was observed on `wip/aarch64-forkcow-signed`, a branch that does **not** contain
upstream commit `af27ba4b7` ("libext: real fsync + page-cache bridge for
ext2/3/4", merged 2026-08-07). On that branch:

```c
#define ext_fsync     ((vnop_fsync_t)vop_nullop)
```

`fsync(2)` on ext4 was a literal no-op, so PostgreSQL's fsync never flushed
lwext4's write-back block cache. lwext4 was never told to make anything durable.
Current `upstream/master` implements `ext_fsync` properly (it calls
`ext4_block_cache_flush` under the bcache lock), which is exactly the barrier
case B proves lwext4 honors.

**Action:** retest ext4-on-arm for PostgreSQL on a base containing `af27ba4b7`
before making any claim about ext4 durability on OSv. The "ext4 is unusable for
PostgreSQL" conclusion in `.local/ROADMAP.md` and the milestones doc is not
supported by evidence and is probably wrong.

Note this is a specific instance of a broader problem: the long-lived benchmark
branches are ~24 upstream commits stale and are missing merged OSv fixes on the
very paths their results depend on. See the BRANCH FRESHNESS / STALENESS
EXPOSURE section of maintenance report round 4 (plan phase P0.4).

## Rebuilding

`build.sh` expects a lwext4 checkout at `/tmp/maint4-lwext4` (removed after the
run to save space):

```sh
git clone --depth 1 https://github.com/osvunikernel/lwext4.git /tmp/maint4-lwext4
mkdir -p /tmp/maint4-repro && cp lwext4-create-durability.c build.sh /tmp/maint4-repro/
bash /tmp/maint4-repro/build.sh && /tmp/maint4-repro/repro
```

The bundled cmake build is not usable on this host (its
`cmake_minimum_required` predates CMake 3.5 support removal), so `build.sh`
compiles the sources directly. The reproducer supplies the six per-fs lock hooks
(`bcache_lock`, `inode_alloc_lock`, `block_alloc_lock` and their unlocks) that
the OSv fork requires consumers to install; without them the fork segfaults on a
null call in `ext4_block_set`, which is itself worth knowing.
