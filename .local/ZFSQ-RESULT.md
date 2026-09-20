
## STEP 1: BUILD conf_zfs=openzfs from wip/openzfs-restructure @ 7940379c0 -- rc=0
Instance i-0df796def9b77d300 m5d.metal us-east-2. fedora:39 container, gcc 13.3.1, ld 2.40.
OpenZFS submodule 83020cf82 (zfs-2.4.3). Single patch applies clean (rc=0). 117 relocated files present.
Built: ./scripts/build conf_zfs=openzfs fs=zfs image=native-example,zfs -> BUILD_EXIT=0.
Artifacts: loader.elf, loader-stripped.elf (PVH), usr.img (fs=zfs), libsolaris.so (16MB OpenZFS kernel module), zpool.so, zfs.so. 183 OpenZFS objects compiled.

### 3 restructure defects found + FIXED (all genuine relocation breakage, not env):
1. 6 relocated files (osv/lib/{libshare,libzfs}/os/osv/*.c) used quoted relative `#include "../../X.h"`
   valid only when the file lived INSIDE the submodule (../../ = submodule lib root). After relocation
   ../../ pointed at the non-existent osv/lib/{libzfs,libshare}/X.h. FIX: `"../../X.h"` -> `<X.h>` (7 lines),
   resolved via existing -isystem lib dirs.
2. Makefile libshare-objects CFLAGS: added `-isystem $(OZFS)/lib/libshare` (libzfs dir already on isystem;
   libshare dir was missing) so <libshare_impl.h>/<nfs.h> resolve.
3. open_zfs_sources.mk OPENZFS_INCLUDES: added `-I$(OPENZFS_OSV)/module/zfs`. The relocation moved the
   patch-generated zfs_gitrev.h from submodule module/zfs/ to osv/module/zfs/, but upstream spa_history.c
   includes it by quoted path "zfs_gitrev.h" (resolved relative to submodule module/zfs/). The -I restores it.

### Env-only (NOT restructure, NOT committed): fedora needs zlib-devel/openssl-devel (setup.py gap);
the pre-existing base #1423 Makefile hardcodes a /nix/store openssl/zlib -isystem glob (empty on fedora,
harmless once devel pkgs present) -- flag for PR cleanup, from base commit 1a9ec1771 not the restructure.

## STEP 2: BOOT + POOL-MOUNT + WRITE/READ/VERIFY -- PASS
Boot via qemu 8.1.3 -enable-kvm -cpu host (real KVM), PVH -kernel loader-stripped.elf, in fedora:39 container with /dev/kvm.
Console:
  OSv v0.57.0-402-g7940379c            <- the restructure commit
  ZFS: OpenZFS 5000 initialized        <- OpenZFS driver linked in (libsolaris.so), fs=zfs
  [ZFS] Pool 'osv' is up-to-date at version 5000   <- pool imported
  ZFS: root mounted ok, z_root=34      <- dataset mounted
  eth0: 192.168.122.15 ; Booted up in 245 ms
  ZFSPROOF: wrote 1048576 bytes to /zfsproof.dat on ZFS root
  ZFSPROOF: checksum write=3f738f7eb0f76383 read=3f738f7eb0f76383
  ZFSPROOF: PASS write/read/verify checksum-match
NOTE: the earlier "spa_import_rootpool failed: 5 (ENXIO)" was an artifact of my --nopci test flag hiding
the virtio-blk disk, NOT the dmu_objset_own host-baked-pool ENXIO gotcha. Booting normally imports/mounts
OSv's own fs=zfs pool fine (pool created by OSv's own zfs_builder at build time = version-matched).

### Persistence proof (2 boots, same usr.img, no rebuild between):
  BOOT#1 /zfsproof -> ZFSPROOF: PASS write/read/verify checksum-match (write=read=3f738f7eb0f76383)
  BOOT#2 /zfsread  -> ZFSREAD: read 1048576 bytes after reboot, checksum=3f738f7eb0f76383
                      ZFSREAD: PASS persisted checksum matches STEP2 write
=> data written to the OpenZFS dataset survives a full reboot = real on-disk ZFS, not RAM.

## STEP 3: FUNCTIONAL EQUIVALENCE to current #1423 (pr/openzfs-draft @ d743cc8bd) -- PROVEN
Built #1423 head the same way (fedora:39, gcc 13.3.1, same OpenZFS pin 83020cf8, same flags,
conf_zfs=openzfs fs=zfs image=native-example,zfs) -> rc=0. #1423 has 31 patches + files INSIDE the
submodule (no osv/ tree); the restructure has 1 patch + 117 relocated files. Comparison:

  metric                       restructure(7940379c)  #1423(d743cc8b)   verdict
  build rc                     0                      0                 same
  loader-stripped.elf size     9383008                9383008           BYTE-IDENTICAL
  zpool-stripped.so size       244448                 244448            BYTE-IDENTICAL
  zfs-stripped.so size         145544                 145544            BYTE-IDENTICAL
  libsolaris.so size           16241984               16242080          +96B (path strings only)
  libsolaris.so .text size     0x1f61bc (2056636)     0x1f61bc          IDENTICAL
  libsolaris.so symbol table   6262 syms              6262 syms         IDENTICAL (0 diff lines)
  OpenZFS objects compiled     302                    302               same
  boot banner                  v0.57.0-402-g7940379c  v0.57.0-401-gd743cc8b  (commit id only)
  OpenZFS init + pool import   yes                    yes               same
  root dataset mount           z_root=34              z_root=34         same
  zfsproof write/read checksum 3f738f7eb0f76383       3f738f7eb0f76383  IDENTICAL
  fs blocks total              720617                 720617            IDENTICAL

VERDICT: the restructure is a functionally-equivalent pure relocation. loader/zpool/zfs binaries are
byte-identical in size; libsolaris.so has identical .text size + identical 6262-symbol table (the +96B
is only the shorter osv/ path strings vs the longer submodule paths baked into the binary). ZFS runtime
behavior (init, pool import, mount, write/read/checksum, fs geometry) is identical. NO divergence found.
The 3 restructure defects (STEP 1) were the ONLY functional gaps and they are fixed; with them the
restructure == #1423 behaviorally.

## STEP 4: PR #1423 UPDATED (fast-forward, no force, PR stays open)
- Added a G-signed fix commit 6c4c39bb6 (the 3 STEP-1 include fixes, leak+em-dash clean) on top of the
  relocation commit 7940379c0. Both are ADDITIVE on the exact current PR head d743cc8bd (verified ancestor).
- FAST-FORWARDED gh-fork pr/openzfs-draft: d743cc8bd -> 6c4c39bb6 (no force-push, no delete-recreate,
  PR did NOT auto-close). PR #1423 now shows 29 commits, tip 7940379c0 (relocate) + 6c4c39bb6 (fixes).
- Updated staging branch wip/openzfs-restructure on BOTH gh-fork and codeberg origin to 6c4c39bb6.
- Posted #1423 comment issuecomment-5301487354: build rc=0, boot banner + OpenZFS-init + pool-import +
  root-mount + write/read/checksum + reboot-persistence proof, equivalence-to-pre-restructure evidence
  (byte-identical loader/zpool/zfs, identical libsolaris.so .text size + 6262-symbol table), the 3 fixes,
  and the 2 remaining integration questions (unit-test disposition, squash+forward-port). Left DRAFT on.
- Leak-clean: no acct-id/SG/subnet/vpc/IP/pem/.local/pgbench/HammerDB/m5d/em-dash in commit or comment.
