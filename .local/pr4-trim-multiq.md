# PR 4 - block: TRIM/DISCARD support and multiqueue I/O

**Branch:** `gburd/osv-1:pr/trim-multiq` -> `cloudius-systems/osv:master`
**Base:** stacks on PR 3 (`pr/pagecache`, d06461bf). One-commit branch:
8b15bc96.
**Verified:** kernel compiles + links clean on GCC 14.3 / Boost 1.87
(via the PR 6 tip). tst-vblk-multiqueue, tst-zfs-trim, tst-zfs-direct-io
PASS on the ZFS image.

---

## Title

block: add BIO_DISCARD (TRIM) and per-CPU multiqueue I/O to virtio-blk

## Body

Two block-layer features the ZFS and Crucible drivers depend on.

### Changes

- **BIO_DISCARD**: a new block-layer request type plumbed into
  virtio-blk's request descriptor (VIRTIO_BLK_T_DISCARD). Maps to
  ZFS's ZIO_TYPE_TRIM and to Crucible's protocol-level discard.
  Drivers without discard support return ENOTSUP; the caller falls
  back to overwrite-with-zero.
- **Multiqueue**: per-CPU queue dispatch in virtio-blk so a 16-vCPU
  guest submits I/O on 16 queues concurrently. Adds a scripts/run.py
  helper wiring QEMU's num-queues, a per-queue completion-notifier
  locking-race fix (the lock was released too early under preemption),
  and a sys/dev `device_delete_child` return-type fix surfaced while
  threading the multi-queue teardown path.

### Notes

- Fifth in the series. The TRIM path is exercised end-to-end by the
  ZFS PR (ZIO_TYPE_TRIM -> vdev_disk -> BIO_DISCARD).
- docs/block-discard.md and docs/block-multiqueue.md document the two
  features; tests/test-discard.sh and tests/test-multiqueue.sh are the
  manual exercisers, with tst-vblk-multiqueue as the in-tree test.
