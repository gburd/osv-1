# PR: bound MSI-X vector use so many-queue guests still boot

Bundle: `.local/prmaint-bundles/prmaint2-msix-vector-budget.bundle`
Branch: `pr/msix-vector-budget`  base: `ae077860c` (upstream/master)
Commit: `8763dadf8` (author Greg Burd; needs your ED25519 re-sign -> sig G)

## To land (new branch, normal push):
```
git fetch <this-bundle>            # or cherry-pick the commit onto a fresh pr/msix-vector-budget off upstream/master
git verify-commit 8763dadf8        # after you re-sign
git push gh-fork pr/msix-vector-budget            # normal push (new branch, NO force)
# then open PR against cloudius-systems/osv master
```

## PR title
`drivers: bound MSI-X vector use so many-queue guests still boot`

## PR body
The x86-64 IDT exposes only 224 usable interrupt vectors (32..255), shared by
every device. A guest with many vCPUs and several multiqueue virtio devices
can request one MSI-X vector per queue and exhaust the pool during boot. When
that happened two things went wrong:

- `register_interrupt_handler()` called `abort()` when no IDT vector was free,
  crashing the boot instead of letting the device degrade.
- `request_vectors()` pushed a `msix_vector` whose allocation had failed, and
  `~msix_vector()` then unregistered vector 0.

This bounds vector use so the guest boots either way:

- `register_interrupt_handler()` returns 0 (an impossible real vector, since
  0..31 are CPU exceptions) as an "exhausted" sentinel instead of aborting.
  `msix_vector`'s destructor skips the unregister when its vector is 0, and
  `request_vectors()` stops at the first failed allocation and returns the
  short vector it did get. The existing `easy_register()` already treats a
  short result as failure, so a driver falls back to fewer queues rather than
  crashing.
- Adds `virtio_driver::reserve_msix_vectors()`, a process-wide soft budget a
  multiqueue driver consults to cap how many queues it arms with a distinct
  interrupt, leaving headroom for other devices and always granting at least
  one. virtio-blk uses it to cap its active queue count; extra probed
  virtqueues are simply left unused.

## Verification (host: an x86-64 bare-metal build host, GCC 11.5)
- Applies clean on master; all 5 changed files compile clean; whole kernel
  compiles (1198 objects) with the patch applied.
- `reserve_msix_vectors` resolves within the driver files (defined in
  virtio.o, referenced in virtio-blk.o); a partial link of the changed
  objects resolves with no dangling references.
- NOTE: the boot A/B (a high-vCPU guest with several multiqueue virtio-blk
  devices aborting on stock, booting on this change) was demonstrated during
  the multiqueue work this was extracted from; this standalone extraction is
  compile- and link-verified.

## Provenance
Extracted from the virtio-net multiqueue draft (#1463): this is the
vector-budget boot fix, cleanly separated from the multiqueue machinery,
which is the genuinely useful standalone piece. Leak-clean (scanned), no
em-dashes, Signed-off-by Greg Burd.
