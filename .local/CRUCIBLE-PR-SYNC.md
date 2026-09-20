# Crucible PR (#1424) sync + the physio fix split (2026-09-13)

## Verdict: #1424 was ALREADY in sync with upstream. It did not need updating.
- merge-base(upstream/master, #1424 head cdb02c912) = 0e34e4dc2 = CURRENT master. Zero master commits
  missing; the PR contains all of current master. Master unmoved since 2026-08-17; PR rebased 2026-08-26.
- merge-tree vs master: CLEAN. GitHub mergeable=MERGEABLE (correct this time).
- SELF-CONTAINED: no dependency on any other open PR. All crucible symbols defined in its own files.
  The bio/device APIs it calls (bio_bcount/bio_cmd/bio_data/bio_dev/bio_error/bio_offset/biodone,
  device_create/devops) all exist on current master - API-current.
- The Kconfig "gap" I suspected was UNFOUNDED: drivers use the profile/generated-header mechanism, not
  kconfig. base.mk:86 `export conf_drivers_crucible?=0` -> gen-drivers-config-header emits
  `#define CONF_drivers_crucible` (verified: emits =1 under the crucible profile). Wiring complete.
- Comment history confirms it was previously blocked on #1398/#1400/#1423, all merged, and already
  rebased+un-drafted. The dependency sync was done; nothing had drifted since.

## The REAL improvement: split the general physio() fix into its own PR
#1424 bundled a general VFS bug fix inside a 6878-line experimental driver. `fs/vfs/vfs_bdev.cc`
`physio()` set bio_bcount = uio_resid (total uio length) while bio_data points at one iovec's base ->
a multi-iovec write hands adjacent memory to the device as data. Also a zero-length leading iovec spun
the loop forever (continue without advancing uio_iov). Both still present on current master (verified:
line 210 `bio_bcount = uio->uio_resid`, line 195 the `!iov->iov_len` continue). The sibling function
earlier in the same file already does it correctly.

FILED: PR #1508 "vfs: issue one bio per iovec in physio(), with the correct length" - the 20-line fix
extracted onto master, comment reworded to be driver-agnostic, G-signed ce54c5cb3, merge-tree clean.
Disclosed on #1424 (issuecomment-5655135176) that the fix is now split out. This lets a real,
general block-layer correctness fix land on its own merit instead of being gated behind an experimental
driver - and it enters the projected-merged base as a small, obviously-correct PR.

## Note for the projected-merged base
#1424 (Crucible) stays on the PG-scope deny-list (Crucible distributed storage is not the local-NVMe
PG workload). But #1508 (the physio fix) is a general VFS correctness fix and SHOULD be IN the
projected-merged base - it affects every driver's multi-iov write path, including virtio-blk under ZFS.
Add #1508 to the IN set on the next base build.
