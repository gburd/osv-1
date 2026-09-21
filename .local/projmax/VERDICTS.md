# Per-PR verdicts, projected-max composition (LIVE - updated as established)

Base: gh-fork/bench/native-substrate @ 75f421ae3 (177 commits on fork point cb8c7205b).
Composed branch: gh-fork/bench/projected-max.

## METHOD (and why the brief's numbers differ from mine)
Presence measured by PER-HUNK reverse-apply in a worktree checked out AT the base,
cross-tabbed with a FORWARD apply. The cross-tab is the part the brief lacked:

  REV=all   FWD=fail  -> PRESENT       base carries it; patch redundant
  REV=none  FWD=clean -> ABSENT-CLEAN  genuinely missing, applies => ADD
  REV=none  FWD=fail  -> DIVERGED      base has a DIFFERENT version of the same
                                       region, OR the path does not exist at all.
                                       A reverse-only test calls this ABSENT. That
                                       is a FALSE ABSENT and it is 24 of the brief's
                                       39 "PARTIAL" entries.
  REV=some            -> PARTIAL       mixed; per-PR judgement

## STRUCTURAL FINDING THAT DRIVES MOST VERDICTS
The base is NOT a descendant of upstream/master: fork point cb8c7205b, 24 commits
behind. One of those 24, 0e34e4dc2, RESTRUCTURED modules/open_zfs:
  upstream/master: modules/open_zfs/osv/module/os/osv/zfs/*.c as checked-in sources
                   + 1 patch file
  this base:       NO modules/open_zfs/osv/ at all; the OSv platform layer is 43
                   sequential .patch files applied to a vendored openzfs checkout
So 37 of the 58 PR heads sit on the NEW structure and 21 on the OLD one, and
"diff vs upstream/master" means two different things depending on the PR.
Any PR whose head is on the new structure and which touches modules/open_zfs is
STRUCTURE-MISMATCH, not absent.

## ADDED (in the composed image)
| PR | what | verdict | evidence |
|---|---|---|---|
| #1513 | zfs vdev_nonrot | **ADDED, via 51f69a04c's patch form** | PR head 18194d253 edits modules/open_zfs/osv/.../vdev_disk.c, a path ABSENT from this base => cherry-pick impossible. bank/iouring-completion-fix @ 51f69a04c carries the identical semantic change as patches/0044, which fits the 43-patch structure. Applied. Runtime proof added (0045). |
| #1494 | bootfs deps on ZFS lib for any ZFS build | ADDED | applied clean; merged with #1496 (same ifeq region) |
| #1496 | order mount tools before bootfs for fs=ramfs | ADDED | applied clean after merging with #1494; REPLACES the native build script's hand-rolled workaround |
| #1450 | validate device-supplied completion ids | ADDED | applied clean, no resolution |
| #1508 | physio one bio per iovec | ADDED | applied clean; NO in-tree caller => inert for this workload, included for completeness |

## COMPOSED-IN FIXES FOUND WHILE COMPOSING (not from any PR)
| item | what |
|---|---|
| 0044 hunk count | patch 0044 declared `@@ -103,6 +103,32 @@` for a 37-line body => `git apply` rejected it as corrupt and ONLY the Makefile's `--recount` retry rescued it. A patch that needs --recount is one silent skip from a build that reports success with the fix absent. Corrected; now applies with a plain apply. Build log confirms 0 skipped patches. |
| 0045 runtime proof | NONROTPROOF (resolved flag, once per vdev) + VDEVIO (bio count, ABSOLUTE bytes, count of requests >128 KiB, every 10 s). gt128k is the binding proof: with vdev_nonrot correct, vdev_queue_aggregate() cannot emit a span above SPA_OLD_MAXBLOCKSIZE. printf, not debugf. |
| base gate ancestry | .local/bench-base-gate.sh checked 9 content markers and never asked if the base was current, which is how a base 24 commits behind passed for weeks. Now asserts descent from upstream/master; BENCH_ALLOW_STALE_BASE=1 overrides and PRINTS the distance. |

## PRESENT IN BASE (9, all confirmed: every hunk reverse-applies)
#1465 #1471 #1479 #1480 #1481 #1485 #1486 #1504 #1507
Brief agreed on all 9. No action.

## THE 24 MERGED-UPSTREAM COMMITS MISSING FROM THIS BASE (and from every recent benchmark)
See RESULT.md section 2. Most pointed: ae077860c "virtio-blk: do not hold the
per-queue lock while draining completions" - a lock-contention fix on a path whose
signature matches the wall we are chasing.

## THIRD-PARTY PRs (NOT ours to land; read only, per operator request)
| PR | author | relevance to native NVMe/ZFS PG | note |
|---|---|---|---|
| #1390 | wkozaczuk | **RELEVANT, and we do not have it** | mutex: spin in lock() before blocking. Our stack has ZERO mutex spinning: `grep spin core/lfmutex.cc` on the composed tree returns NOTHING. So a contended-mutex-context-switch mechanism is fully un-mitigated in every number this campaign has produced. This is the closest thing to a candidate fix for the "59.2% CPU, 13.1 vCPU idle, cannot go faster" signature. NOT added (not ours, and it ships with 6 CONF_ macros still in tuning state). |
| #1466 | wkozaczuk | INERT here (NVMe, not virtio-blk) | **DESIGN CONFLICT with our #1509, confirmed from the diffs.** Both rewrite the same virtio-blk completion path to one thread per virtqueue. His body says it "reverts some of the changes made to have a single completion thread handle all queues"; ours (#1509) makes per-queue completion an OSV_BLK_MQ_COMPLETE-gated option defaulting on, KEEPING the single-thread path as the fallback. Same goal, incompatible shapes: his is a replacement, ours is a switch. Net -162/+108 for his vs +133/-31 for ours. These cannot both land; someone must choose. Also note his PR sets run.py num-queues=1, which would change the default our #1509 measurements were taken under. |
| #1215 | gohar94 | inert | ht_enabled -> smt rename, cosmetic |
| #1288 | wkozaczuk | inert for this workload | signals: switch to app TLS if available; PG uses signals but not from a non-app TLS context on this path |
| #1338 | nmeum | inert | SCHED_RR policy; PG does not set RR scheduling |
