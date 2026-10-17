# Upstream inventory — current snapshot 2026-10-17 (added stub-fix PRs #1560-#1562 and lwext4 0002 on #1533; checked by .local/check-inventory.sh)

**96 open PRs total = 90 OURS (81 non-draft + 9 draft) + 6 third-party.**
Non-draft is GitHub state, **not ready-to-merge or validated**. All-author REST query,
`gh api --paginate --slurp 'repos/cloudius-systems/osv/pulls?state=open&per_page=50&sort=created&direction=asc'`,
returned pages of 50 + 38. Counts derived from saved JSON, not a hand-listed denominator.
Receipts: `.local/maint/receipts-20261012T095006Z` (inventory-live-*.json, inventory-corrected-rows.md); prior inventory: `.local/UPSTREAM-INVENTORY.pre-20261012.md`.
Authors: gburd 90, wkozaczuk 3, nyh 1, nmeum 1, gohar94 1.
Stub-fix batch opened 2026-10-17 (audit follow-ups, validated on gcc 14 Fedora): #1560-#1562 added
below; #1533 gained a second commit (lwext4 patch 0002, head 4f06e2282). integ carries all four.
Locale series published 2026-10-15/16: #1555-#1559 added below; #1477 reworked
(new head/title). integ carries all six (see below).

Master (fresh upstream API and upstream/gh-fork/origin ls-remote; local master/upstream/master agree):
`872f606b7a5e29b081147b545a0eb0db5098fd14`. No sync needed or performed.
Integration: `integ/pg-master` = `de9ee87fe` (carries the six locale PRs on the Round 4 set
plus the four stub-fix/lwext4 additions #1560-#1562 and lwext4 0002). Re-gated 2026-10-17 on
Fedora gcc 14: clean build (conf_zfs=bsd, fs=ramfs, 0 errors) and the four new fixes pass in the
full integ context (tst-faccessat 22/0, tst-pthread-cleanup 6/0, tst-pthread 10/0, tst-vfs clean);
lwext4 both patches apply (5 EIO guards present). conf_zfs=openzfs did NOT build on gcc 14 due to
PRE-EXISTING OpenZFS-port strictness (zfsvfs_create implicit decl, zfs_file_open conflicting
types) that none of the four commits touch; the prior gate used gcc 15.3 via the Nix dev shell
with its own documented ZFS-image caveat (INTEG-REFRESH-SPEC.md). OpenZFS-on-gcc-14 is a build-env
gap to resolve separately, not a regression from this batch.
Prior gated head: `442d258ba33aed12d043ddf0a5f2796a632148fd` (full-build + zfs test.py 198/0/2, 2026-10-16).
Record: `.local/teams/crucible-9p/publication/PUBLISHED.md`; manifest `build/integ-r5c/manifest.r5c-base.txt`
plus the integ-only locale steps `refs/r5/integ-stack`, `refs/r5/integ-s2`.
(#1477's 2026-10-16 respin is comment-only, so integ's compiled content is unchanged;
the #1477 manifest row moves to da4080f95 at the next refresh.)
The complete remediation/coverage plan is `.local/remediation-next/CATALOG.md`.
Inventory and integration gates **NOT RUN**: their tooling defects must first be repaired and
independently negative-tested through their real interfaces. The old check demands the misleading
word “ready”; this file deliberately does not accommodate it by making a false readiness claim.

## OUR 81 NON-DRAFT PRs

  #1439 signal: implement signalfd(2) — `21cac540708ee6629274d11a0b6945e03418598a`
  #1440 fs: implement inotify(2) — `2e4ff0ce2a878223b9613ebd46e062d870d754eb`
  #1441 mm: add node-preferring page allocation (alloc_page_on_node) — `32731f4bf2d26bf0ef21e305a2ccc75dff24b2dd`
  #1442 net: forward-port FreeBSD IPv6 stack with SLAAC and DHCPv6 autoconfiguration — `f6f7d75ca5331f07da35d8ffd8725c99e97d7811`
  #1449 libext: fix heap overflow in ext_readlink and ext_readdir from a crafted ext4 image — `85ad6ec56a9c33565f1551e5a3c07275387713d1`
  #1450 drivers: validate device-supplied completion ids (virtio used-ring _id, NVMe cid) — `d3bdca5bcddcd54458cf2a4d1e123a7ee8026f98`
  #1456 mm: per-child copy-on-write address space for fork() (opt-in, stacked on #1455) — `a83d39400530cccb1234f8e3fb88934214984e3b`
  #1459 zfs(openzfs): enable OpenZFS on aarch64 (follow-on to #1423) — `03b5735736e8130afbd67cfe227b8ebdf5a1199b`
  #1461 random: reseed the CSPRNG on hypervisor resume so snapshot clones diverge — `96978d0e82fd1805c33d024ed3ebc65caf0fdd48`
  #1463 virtio-net: implement multiqueue (VIRTIO_NET_F_MQ) — `1454fd42f3871bb1cb1c2dde97edc4e19e0e48c3`
  #1464 sched: disperse threads faster in the load balancer — `512b2b2ec5459b1c2a2d04ecfe443a2365363510`
  #1465 drivers: bound MSI-X vector use so many-queue guests still boot — `dfe6b67b4c7aaf18d5a1f6d815afa36da1ae8e86`
  #1467 net: batch per-connection wakeups in the virtio-net receiver — `defb369498f427b8b83c5219386bb24f63599b21`
  #1470 virtio-net: implement RSS (VIRTIO_NET_F_RSS) receive flow steering — `c1663dd21b9dc006eb3b073d9e8bbd926b388b4e`
  #1471 drivers/ena, drivers/nvme: fix inbound TCP on AWS Nitro (RSS indirection + NVMe MSI-X budget) — `c3c0bcde42d307f91929258f5910e59d59b87388`
  #1472 sched: idle-CPU pull work-stealing to disperse woken threads under concurrency — `7053800d6fc88361bee182add8f9abe7a038ed89`
  #1477 libc: give the locale functions glibc's behaviour — `e6ff949dfe9b6f9c2e6573f793bcae8d695c6ab0`
  #1478 zfs(openzfs): enable a runtime ZFS data pool on a non-ZFS-root image (follow-on to #1423) — `25bde6b9622e98d12a9fad7d347ad8be98944ca6`
  #1479 drivers/nvme: deepen the IO queue and PRP-list cache for concurrent load — `648f7b336f4c2bfa6d564975df058a33be63430a`
  #1480 sched: take the lock before checking the wait queue in condvar wake_one/wake_all — `d9fea9f604b50fc41c04d71563f59b2e71cef4a1`
  #1481 drivers/nvme: make interrupt coalescing opt-in, default off for low latency — `609076dc11ec260a9ee50095dbb4815ed3898ced`
  #1482 numa: bound SRAT/SLIT parsing against untrusted ACPI table lengths — `18926d017a744979e9c4953a01f395b3c5f3baf8`
  #1483 pagecache: report page-writeback errors from sync() by return value — `9f06b5f9da889b2e2237aeec54cc3947d35c863d`
  #1484 sched: skip waking a null or invalid thread pointer — `0635717f84557a25bbe5dd33b99b8bbc9d5733e7`
  #1485 fs: raise default max file descriptors from 16384 to 65536 — `0347a7d04e064d5f26e22e0fd356119c6c0928d0`
  #1486 bsd/callout: treat a null callout in callout_reset_on as a no-op — `dd500ab9bc665023bc721f5e85d523aad96de678`
  #1487 zfs(openzfs): cap the default ARC at half of RAM for app coexistence — `ec5c557a9ab0f4dacfdfce93e1e19264fd30d34b`
  #1488 open_zfs: bump vendored OpenZFS to 2.4.4 and adapt the OSv platform layer — `cb23ebdf39e96f014a460d77d0d15f6f7cbfb05c`
  #1490 aarch64: cover all of physical memory in the temporary phys map — `471ed7f223653a8e12dffa352c279c8db8fc7ce3`
  #1491 aarch64: do not cap GICv3 SGI targets at 16 CPUs — `1c4f506f851d49d3921fa169562655b026afb6fd`
  #1492 random: satisfy early /dev/random reads from RDRAND instead of blocking — `4f63d80ac3c21954fce354c93075307d4fa054dd`
  #1493 aarch64: satisfy early /dev/random reads from RNDR (FEAT_RNG) — `b6f8fe97124c511f5149505f5cbb6f39fc3825cd`
  #1495 build: fail the build when the OpenZFS patch series does not apply — `7c306295f8594a598d4f26d14d1c422c68edf022`
  #1496 build: order the mount tools before bootfs for fs=ramfs — `ed3df44a882170036d24a1c852843e6529d61445`
  #1497 zfs: let each ZFS provider carry the libsolaris.so manifest entry — `c462b0cab2db8eaa2c88a5fa63c9c1e13dc83c03`
  #1498 drivers/ahci: fix boot hang when an AHCI port presents an ATAPI device (breaks all q35 boots) — `34bcf8c93350303e02a5ef8a881c5b8e60ee02ac`
  #1499 drivers: allocate block device names from one shared namespace — `9caff8e525b7b2f5bac990c31135fdd5887ae8dc`
  #1500 lwext4: pin the checkout to an exact commit — `e4010abd666f37e6cf3d818df02a697864b89fcb`
  #1502 vfs: fix AB-BA deadlock between dentry_hash_lock and the vnode lock — `9f7245fe4033f4d0d230397bb37825230254ff4b`
  #1503 vfs: split the global dentry hash lock into per-chain locks — `6daaeeef3b8c33bc1578ba155d0660011a821455`
  #1504 x64: cover the psABI stack and pointer guards in the thread control block — `2f77155a73a17f5da85a853e44f200a3c230dd7b`
  #1506 zfs: allow an explicit ARC ceiling via OSV_ZFS_ARC_MAX — `98b5e58c45b13ccf081889292e49dcac3bb669c8`
  #1507 pagecache: skip the whole-file writeback scan on fsync when nothing is dirty — `9fb78af4b75f53c922aeaeeec7263df76ff6bba4`
  #1508 vfs: issue one bio per iovec in physio(), with the correct length — `75bb43bf690629b01e3e5717f02f94585d256237`
  #1509 virtio-blk: optional per-queue completion threads (OSV_BLK_MQ_COMPLETE) — `894492eda53e2e63f3199231105fb083724e9ad2`
  #1511 sched: adaptive per-CPU idle-spin window (guest-side halt-polling) — `2be3701f010096169da63393776b49ee0bd34d78`
  #1512 bench: durable-write latency isolate with concurrent writers in zfs-bench — `1cdbe3541415450ddd72098c4006436ea73bcef3`
  #1513 zfs(openzfs): report vdevs as solid state (vdev_nonrot) — `18194d2532b45b6055daa6ede572cd05c7fdaf1b`
  #1514 build: bootfs.bin must depend on libsolaris.so in every configuration — `f61a45d589f98579c87aa8aa49a467546d482068`
  #1515 backtrace: unwind the interrupted thread when sampling from an interrupt — `4d4ea68bb57a7ab50dba3cabd8e104eb78b8a2fb`
  #1516 vfs: grant the superuser discretionary access in vn_access — `81bee8a38eb7cbadb315813d2f2bd35cda184024`
  #1517 libc: upgrade musl from 1.2.1 to 1.2.6 — `ec79aa15eefd791d3f0f2b31499358106eec546a`
  #1518 aarch64: read the 16550 console address from reg, not the node name — `79bb556d16b20fcd5c3980f606bd954549652873`
  #1519 arch/x64: minimal PMU (performance-counter) readout — `388da6d8ed8f81a21c941f56dffd7ea3d2dae38c`
  #1520 scripts/loader.py: fix 'osv info threads' under GDB 15.x when sourced explicitly — `69a44988ca5a8ae0c861525cd923c098c3a91283`
  #1521 sched: support more than 64 CPUs — `b648cda0c10f8e75ad7e7ed35206d71d451ec2e7`
  #1523 virtio-rng: wire MMIO interrupts and validate completion lengths — `5312f62a38753b497bb8da082202ea3f3e26ca89`
  #1525 vfs: preserve nonblocking I/O flags at device boundaries — `664c2522c60012962a0cde4455cd07f2fb99830f`
  #1527 vfs: keep the dentry cache unchanged when rename fails — `07d120e130efa57bf6462435962bfe13f548a5d1`
  #1528 virtio-balloon: define PFNS_PER_REQUEST for odr-use — `9ee9d876cd8e00b94ce019ec5bb681fa2ccaaa28`
  #1529 aarch64: drop the generic-timer frequency upper bound — `ba9db475407b6e11385a53a30df490c4c3b60b16`
  #1530 vfs: read fcntl arguments by command and report no conflict from F_GETLK — `4ed40ac4cafeba241e191bf762c2e12b560869af`
  #1531 vfs: refuse unmount while a mount has users, and pin lookups against unmount — `052141666c186c1d9fb17e208541db0c11d6e2f6`
  #1533 lwext4: validate extent headers and the superblock block size (+ patch 0002: reject crafted group descriptors) — `4f06e2282f7bd03062ef467ee4b966ed1c786a20`
  #1534 virtio: report feature negotiation refusal — `66cd6f2c68763332b30ea93f0409b20c57c48635`
  #1537 vfs: let a filesystem create and open a file in one step — `0a30cb5112154175771804000dc2db55e5437c7e`
  #1542 vfs: release the mount's dentries in rofs, virtiofs, ext and nfs unmount, and keep them on a refused bsd ZFS unmount — `b2c216dfc18e7457eff3671c69b5fb46d638801c`
  #1544 ramfs: keep a node until the last vnode that points at it is released — `0a68109d9a0b85218274df1a19b3c67c51f311cb`
  #1546 vfs: let a filesystem bypass the name cache and own access and metadata — `51ae4a20b318238db6d92e5e912e8912dc0471cb`
  #1548 vfs: let a filesystem write through the open file — `32ffbfd980783d89bf7667dca60822346248c9bd`
  #1549 9p: a 9P2000.L client filesystem over TCP (opt-in) — `5232a0a865310c24fe08dc476eaa91c88374f459`
  #1553 vfs: keep a renamed directory's cached children on a valid list — `5aafcb3d175b2bfdb0ca135974f2e157c4c40151`
  #1554 scripts: make the zfs image upload wait for cpiod, and fail fast — `9ebea8ad8b4d055147eaba937b6d973ede45ec71`
  #1555 locale: named UTF-8 locales from glibc-format data (conf_locale) — `dcca645aac33bd776e8cbb89893a8ef603a33f49`
  #1556 locale: apply LC_NUMERIC in printf, scanf and strtod — `12c143e87e9838d2795a162b3e4b138ec9cbdebe`
  #1557 locale: LC_COLLATE for strcoll, strxfrm and the wide forms — `6081ee26c567f634db09fff4fb1a137ca812ff0e`
  #1558 locale: gettext and translated libc messages — `8ebd40abe91ceb77a7c6ea65ef37bd1288ca879c`
  #1559 locale-data: a module that ships glibc's compiled locales — `ddcfc68018da65f49db4b19766d8c9b509eccf7b`
  #1560 nvme: fix an off-by-one PRP-list assert that panics at 2 MiB — `86e3530f4f5272be5eb44f110795fa72dbb6de98`
  #1561 vfs: implement faccessat(AT_SYMLINK_NOFOLLOW) instead of aborting — `0f8bb919969128348c6638b9011b3c6f59e903b5`
  #1562 libc: run pthread_cleanup handlers instead of dropping them — `8fd06d832af57dafd9e7c11a69b98151c237f627`

## OUR 9 DRAFT PRs

  #1424 drivers: add Crucible distributed block storage driver — `3d0bc004f10033924f2699101352771cd7293d36`
  #1438 numa: report real topology from getcpu and get_mempolicy — `6c49654846d3ac4cfcf0184a05b9e17ad63fd7a7`
  #1444 [STACKED on #1442] virtio-net: enable IPv6 checksum and TSO offload — `eea48c6ccad55f9227829bacbb0774b2838aaef5`
  #1445 [STACKED on #1441] mm: per-NUMA-node L2 page pools — `d5cdf7f9f4767d34e7bbfa08472614652f4a7d88`
  #1455 process: implement thread-backed fork()/vfork()/execve()/waitpid() (opt-in, off by default) — `fb8fd698e5299f35dcd3a4b4674848c1478b9505`
  #1458 [DRAFT / tracking - DO NOT MERGE as one unit] PostgreSQL-on-OSv fork+ZFS integration (will split into S1..S6 on #1455/#1456/#1457 + #1423) — `d3e9e973dc3a6ef84dd17733b051b099b59724a5`
  #1475 mm: resolve fork COW write faults lock-free when nested (fork-stack follow-on to #1456) — `d4737480850ebc709cdfe416d64eca6b9145a318`
  #1510 libext: ext4 sequential-read performance (read-ahead + async prefetch) — `b5b370fa01292bec97c13f7cfb0ae8d22de7783a`
  #1545 scripts: tooling to compose and verify a projected-merged base from open PRs — `497419797b24136393f7752b1389419d72c1c7fa`

## 6 THIRD-PARTY PRs — owner retains scope/publication authority

  #1215 ht_enabled -> smt — `c46079c3830bf38d89d79de3f6b3d0364aaa865a` (gohar94)
  #1288 signals: switch to app TLS if available — `cc976d128c109733ba31a35e0c20f706d10f3a93` (wkozaczuk)
  #1338 sched: Support POSIX's SCHED_RR scheduling policy — `a8eab2020a2fa3df2ebc86e4f20892e92b749f76` (nmeum)
  #1390 mutex: spin a little in lock() to avoid context switch — `44fbf4dba297a83dcab9fa72af0459b4e81f3f64` (wkozaczuk)
  #1466 virtio-blk: handle completions on the queue's dedicated thread — `56e64ddcc982c788e8cb69e0ff6c449b42851055` (wkozaczuk)
  #1522 Support building on Fedora 44 — `81679d171b2fea18c7e280bae104e8c2949b7a71` (nyh)

#1424 remains draft: reviewed client corrections do not establish fresh-upstream interoperability,
snapshot support or fresh reviewed-head guest durability. #1438 remains draft and depends on corrected
#1482; bounded topology queries are not working memory placement. #1444 stacks on #1442; #1445 needs
allocator/topology correctness and placement proof; #1455/#1456 are fork prerequisites; #1458 is a
DO-NOT-MERGE tracking/composition scope, not an independently safe implementation; #1475 has nested-COW
review obligations; #1510 retains worker-lifetime and remeasurement qualification.

## osv-apps — separately queried at this snapshot

6 open = 4 ours (#71 non-draft, #73 #74 #75: #73/#75 draft) + 2 third-party (#67, #70).
#71 `46098c0fe45aeeaa14d8d8d7bdd41dc0b149ad6d`: reuse existing EC2 diagnostic app; no all-type execution claim.
#73 `3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3`: fork/COW held; source pin/cache/authentication defects remain.
#74 (icu): ICU 78.3 library module; smoke test OSv == host ICU. Non-draft.
#75 (pg --with-icu): DRAFT, stacked on #74 and #73, held on OSv fork/COW; libc + ICU collation == Linux.
Locale series (osv #1477, #1555-#1559) is the kernel side; #74/#75 are the application side.

## Historical bank notes (retained, NOT current eligibility or coverage)

The following older notes preserve leads and corrections, not fresh build/test evidence. The old
“3 banked” count is withdrawn: intent/overlap must be adjudicated against the full readiness ledger.
In particular class-frag's old COMPILES claim is contradicted by FB01's bounded compiler check;
footprint/marker claims are superseded by the corrections below and the new catalog. Maintainer
activity/mergeability and historical benchmark numbers from the prior copy are not current facts.

## 3 BANKED BRANCHES CARRYING WORK NOT YET IN A PR OR IN integ
  bank/fork-arena-class-frag @ 94e091a02   ON MASTER BASE, 185c. The fragmentation fix (header 32->16 + finer
    classes; malloc(40) 128->64 bytes). COMPILES. *** NOT boot-tested. *** Verified NOT in integ.
  bank/fork-footprint-reduction-signed     172c, stale base. The 24.7x footprint fix (74 -> 576 backends).
    Its `as_window` marker is NOT in integ, so this is genuinely unlanded.
  bank/rdseed-superset-on-master @ fe764ba57  ON MASTER BASE, 1c. RDSEED superset; compiles on pure master
    WITH a control. (Its marker shows in integ, so confirm overlap before opening.)
  ALREADY REPRESENTED ELSEWHERE, do not double-count: fork-arena-real-reclaim (ovf_mapped x8 in integ),
    fork-fd-reap-leak-reviewready (release_inherited_fds in integ), fork-lltable-identity-heap
    (in_lltable_new x2 in integ), iouring-completion-fix (superseded by PR #1513).

## WHY THE FORK-DEPENDENT WORK CANNOT BE OPENED AS PRs
fork() DOES NOT EXIST on upstream/master. `osv/kernel_config_fork.h` cannot be generated there, so
core/fork_arena.cc and friends CANNOT COMPILE - proven by build error, not inferred. Five banked fixes (the
fd/gfdt EMFILE leak, fork-arena real reclaim, footprint reduction, lltable identity-heap, class fragmentation)
are gated on #1455/#1456 landing. Opening them standalone would produce PRs that cannot build for a reviewer.


## *** MARKER CORRECTIONS 2026-09-25 (agent A): three content markers here were useless ***
Verified by content diff, which is authoritative; the markers were not:
* `ovf_mapped` (for bank/fork-arena-real-reclaim): appears on NO ref, not even the branch itself. A guaranteed
  false result. TRUTH (git diff --numstat integ vs branch on core/fork_arena.cc = +44/-336): integ is a SUPERSET
  - the branch is an OLDER form. Already in integ, correctly.
* `in_lltable_new` (for bank/fork-lltable-identity-heap): appears on master too, so it cannot distinguish
  presence. Content check still shows the branch is in integ.
* fork-footprint-reduction labelled "genuinely unlanded": it is FULLY PRESENT (48/48 lines).
RULE (again): before a marker is used as a presence/absence test, prove it exists ONLY where it should.
Prefer `git diff --numstat integ <branch> -- <files>`; +0/-0 or integ-superset both mean "present".
