# DRAFT + FLAGGED FOR YOUR REVIEW - do NOT open without a decision

Branch on gh-fork: `wip/native-zfs-fixes` (2 commits, both G-signed, off upstream/master 0e34e4dc2).
Merge-tree vs upstream/master: CLEAN (both commits together).

## Why I did NOT open a PR (Task 7 bar not met)

The Task-7 rule is: open a PR only if genuinely standalone AND merge-clean AND *validated*.
These two commits fail the bar for different reasons:

### Commit 4b `1600b68cb` - random: RDSEED + boot-seed when no HW RNG
- OVERLAPS two already-open PRs: **#1492** (random: early /dev/random from RDRAND) and
  **#1493** (aarch64 RNDR). All three touch `drivers/random.cc` in the same early-read region.
- 4b is a larger reworking: it adds RDSEED (21 references; #1492 has 0) on top of the same
  early-read fast path. Opening it as a fresh PR would collide with #1492/#1493 and duplicate
  the review already in flight there.
- RECOMMENDATION: fold the RDSEED delta into #1492 (or a follow-on stacked on #1492) rather
  than a competing PR. Not a standalone opener.

### Commit 4a `59f4f12ad` - loader: init the ZFS control device when preloading libsolaris
- IS standalone and merge-clean on its own (4a-only tree merges clean vs master).
- 21 insertions / 2 deletions in `loader.cc`: `--preload-zfs-library` now also calls
  `zfsdev::zfsdev_init()` (gated on `opt_init` so the `--noinit` self-initializing ZFS builder
  is unaffected -> no double `device_create("zfs")`), so a `fs=ramfs` image can bring up
  `/dev/zfs` and create a ZFS *data* pool (native BLOCKER-1 in ZFS-MATRIX-NATIVE.md).
- BLOCKER TO OPENING: **not validated end to end.** ITEM 4 in ROADMAP.md states plainly
  "Metal validates the real native boot" - i.e. the real fs=ramfs -> /dev/zfs -> zpool create
  path has NOT been run green on hardware. The host self-check only covered the 4b RNG bit-logic,
  not this loader path. Per the Task-7 rule ("only if ... validated"), this stays a draft.

## If you want to open 4a after a metal validation

Proposed PR title:
    loader: init the ZFS control device when preloading libsolaris

Proposed body (prose, no em-dashes):

    A fs=ramfs image that preloads the ZFS library (--preload-zfs-library) could not create a
    ZFS data pool because /dev/zfs never appeared: the ramfs boot path never ran zfsdev_init(),
    so the ZFS control device was absent and zpool create failed.

    This makes --preload-zfs-library also call zfsdev::zfsdev_init(), gated on opt_init so that
    the --noinit ZFS builder (which self-initializes) is unaffected and there is no double
    device_create("zfs"). With this, a non-ZFS-root image can bring up /dev/zfs and create a
    ZFS data pool at runtime.

    Validated: (FILL IN once a metal fs=ramfs boot creates a ZFS data pool green.)

## My recommendation
1. 4a: hold until a metal fs=ramfs -> zpool create run is green, then open standalone.
   It is a clean, small, sensible fix; it just is not validated yet.
2. 4b: do NOT open as its own PR - reconcile the RDSEED work into #1492/#1493.
