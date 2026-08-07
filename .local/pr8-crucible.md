# PR 8 - drivers: Crucible distributed block storage (+ CI, apps, java/build)

**Branch:** `gburd/osv-1:pr/crucible` -> `cloudius-systems/osv:master`
**Base:** stacks on PR 7 (`pr/openzfs`, f3614fd4). Four-commit branch:
e75eb387 (driver), 3ae7da82 (CI), 81f9701e (apps submodule), 8866a86f
(java/build compat).
**Verified:** full `fs=zfs image=zfs-test conf_drivers_profile=crucible`
build on meh, RC=0. tst-crucible-blk (9/9) against a live 3-replica
downstairs cluster; tst-crucible-zfs end-to-end zpool/dataset/write/
read. Crucible driver is opt-in (conf/profiles/x64/crucible.mk), off in
the default kernel image.

---

## Title

drivers: add Crucible distributed block storage upstairs client

## Body

Add an OSv-native Crucible upstairs client: a network block device
driver speaking the Oxide Computer Crucible V13 protocol to three
independent downstairs replicas, with 2-of-3 read/write quorum
(3-of-3 for snapshots).

### Architecture

- crucible-client.{cc,hh}: handshake (HereIAm / YesItsMe /
  PromoteToActive / RegionInfo / ExtentVersionsPlease), per-job request
  lifecycle, hash-verified reads, concurrent writes.
- crucible-connection.{cc,hh}: per-downstairs TCP socket with separate
  send/recv mutexes; send_exact_with_data() takes the send mutex across
  both header and data halves so concurrent ZFS TXG-sync writes do not
  interleave on the wire.
- crucible-bincode.hh: minimal bincode 1.x encoder/decoder matching
  upstream Rust serde wire layout.
- crucible-messages.hh, crucible-types.hh: protocol structs aligned
  byte-for-byte with the upstream Rust enums and bincode encoding.
- crucible-blk.{cc,hh}: OSv block-device shim exposing /dev/crucible0;
  validates alignment/length, maps to UpstairsClient::{read,write,
  flush}_sync(), threads BIO_DISCARD as ENOTSUP (V13 has no Discard).
- crucible-hash.{cc,hh}: xxh3-128 for ReadBlockType integrity.

### Integration

- Multi-volume: multiple --crucible= flags bind /dev/crucible0,1,...
- Opt-in via conf/profiles/x64/crucible.mk; not in the default image.
- Boot-time CLI flags wired into loader.cc.
- Removed the early Rust scaffolding (osv-sys, crucible-osv crates);
  the driver is pure C++.

### Companion commits in this PR

- **ci** (3ae7da82): Forgejo Actions workflows (build/test/release)
  mirroring the GitHub Actions setup for our Codeberg mirror. Mirrors
  only; do not run against cloudius-systems/osv.
- **apps** (81f9701e): point the apps submodule at our osv-apps fork
  (strict superset of cloudius-systems/osv-apps) adding zfs-demo and
  crucible-basic-test demos. The fork commit also .gitignores the
  crucible-basic-test build artefact (previously committed by accident).
- **java/build** (8866a86f): patchelf java/jshell RUNPATH at install so
  OpenJDK-from-host boots on NixOS; bump java-base to c++14 (Boost 1.89);
  include <stdexcept> in jni_helpers.cc; drop the removed pom.xml
  `<classifier>jar</classifier>`; adjust the libsolaris.so Makefile rule
  for binutils 2.46 weak-symbol visibility. OpenJDK 21 boots on ZFS and
  runs the virtual-thread benchmark 100/100.

### Known limitation (disclosed)

Sustained 1 MiB+ transfers under the QEMU usermode network stack hit a
separately-tracked OSv-kernel TCP issue; the driver passes all tests
against a real cluster and a single 3-replica volume otherwise.

### Notes

- Ninth and last in the series. Depends on PR 4 (BIO_DISCARD) and PR 7
  (ZFS, for the tst-crucible-zfs end-to-end test).
- This PR is large; the CI/apps/java commits can be split out on request
  -- they are bundled because they are the Crucible/Codeberg enablement
  story, but each stands alone.
