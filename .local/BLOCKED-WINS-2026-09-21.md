# Blocked / waiting wins - snapshot 2026-09-21

## *** NEW: WAITING ON @nyh FOR TWO ANSWERS I EXPLICITLY ASKED (he is active again as of 2026-09-20) ***
1. #1502 - the pre-existing `fake`-list double-LIST_REMOVE bug his AI surfaced (dentry_remove puts a dentry
   on `fake` via the SAME d_link the hash chain uses; dentry_children_remove LIST_REMOVEs every child, so a
   child already on `fake` gets unlinked and drele() removes it a SECOND time through stale pointers).
   VERIFIED PRE-EXISTING (byte-identical dentry_children_remove on master; fake/d_link sharing on master).
   MY QUESTION: own PR against master, or fold into #1502? Proposed minimal fix: give the fake list its OWN
   link field rather than teaching the loop to guess.
2. #1508 - MY QUESTION: delete physio() entirely or keep the minimal repair? Evidence for deletion: our
   3-arg physio() has NO in-tree caller (the zvol.c:1429/:1476 hits are the OLD 6-arg BSD form in a file
   that is NOT BUILT - we compile $(OPENZFS)/module/zfs/zvol.o), the only consumer is #1424's driver (2
   lines), and our justification is stale per c8c153047. I recommended DELETION.
Both are scope calls that belong to the maintainer. Not nudging.

## BOTH REVIEWS ADDRESSED, awaiting his re-look
- #1502 -> c7ab5929e (4 commits, all G-signed, force-with-lease). Only CODE change vs what he reviewed is
  the test header; everything else was commit messages making unearned claims. Fixed: the wrong reachability
  argument (replaced with his sys_rename/two-hardlinks-aliasing-one-vnode argument), the observation
  misattribution (the observed production hang was the ALLOCATION-under-lock defect - owner blocked in
  memory::page_pool::l1::alloc_page - i.e. commit 2, NOT the AB-BA inversion, which was found by code
  reading), the "leaf lock" overstatement (it still nests d_lock via dentry_children_remove, consistently),
  the test-header contradiction (it cannot reproduce on ramfs at all: ramfs_link is vop_eperm so the
  hardlink aliasing the race needs cannot be built), DEBUG_VFS-never-builds (vfs.h:50 commented out, defined
  nowhere - offered to make the owned() check unconditional since it is now one relaxed load + compare),
  "14 sites"->7, and the 3 inline nitpicks (owned() replacing the depth counter, duplicate decl, WITH_LOCK).
- #1508 -> 75bb43bf6. Collapsed to bdev_strategy_rw() (+2/-37), which also picks up its uio_iovcnt>0 guard
  (his catch: my loop traded a hang for an OOB read), added the missing range check to match bdev_read/write,
  and removed the history-lesson comment - taken as a GENERAL rule, not just that instance.

## BLOCKED ON THE MAINTAINER (@wkozaczuk merges; last merge 2026-08-17)
- #1464 APPROVED + CLEAN + MERGEABLE = one click.
- #1439 CHANGES_REQUESTED but STALE (all 8 threads answered).
- #1511 (adaptive idle-spin), #1512 (syncwrite bench) - still ZERO reviews.
- Queue: #1502/#1503/#1504, then #1488 (OpenZFS 2.4.4) + #1500 (lwext4 pin), then #1478, #1449.

## THE KEYSTONE - still unanswered
#1455/#1456 fork-stack composition. My S1..S8 proposal (#1458 comment 5718101962, 09-17) + the footprint/
scaling update (5749965679, 09-20) have had NO reply. It gates THREE validated fixes:
 1. LEAK #1 (fd/gfdt EMFILE) - 400-round A/B - bank/fork-fd-reap-leak-reviewready -> S5
 2. LEAK #2 (fork-arena) + 8 cross-AS coherence scopings - 5-gate validated -> S8
 3. FOOTPRINT FIX - 247MB->9.4-12.5MB per backend, FLAT 42->202 address spaces, 576 backends with 42.4GB
    free (a floor), 1.43TB churn recycled from 1.66GB live - bank/fork-footprint-reduction-signed @ 1480fbee1
    (pre-PR: strip probe-only bits WITH a build check; KEEP ovf_mapped - it is the window cursor)

## UPSTREAM, NOT FORK-BLOCKED (6 PRs - the scaling arc's shippable yield)
#1511 | #1512 | #1464 (approved) | #1472 | #1480 | #1484

## OUR COURT, IN FLIGHT
- ZFS WRITE AMPLIFICATION root-cause (agent 2b47fd10, boxes live): ~4.8x amplification (8kB logical in,
  146kB issued out via vdev aggregation) is the real bottleneck - NOT io_uring/async completion, which PG18
  does not even use for writes (pgaio_io_start_writev has ZERO callers; io_uring is reads-only). Also
  chasing the AioUringCompletion liveness wedge (3/11 high-VU cells).
- #1510 (ext4 read-ahead) - DRAFT, needs an ext4 re-measure (EC2).
- The footprint probe/fix split - deferred to PR time WITH a compile check.

## NOT STARTED
- M2/PGXN (every PGXN extension identical OSv-vs-Linux) - the next milestone.

## SETTLED (do not re-litigate)
VU64 wall = footprint churn, not a lost wakeup. Env/getenv scare cleared (putenv runs; only pre-
parse_options consumers affected; a2a ratios are CONSERVATIVE for OSv). "OSv can't use its RAM" REFUTED by
me being wrong - arc_c reached 28,748MB under load; my proposed 2GiB Linux cap would have inflated OSv.
VU32 gap is NOT the ZIL/commit path (nondurable WIDENED it 0.49x->0.063x).

## FOR THE OPERATOR
1. TWO QUESTIONS SIT WITH @nyh (fake-list scope, physio deletion). His answers unblock finishing both PRs.
2. The #1458 keystone still gates three validated fixes - the single highest-leverage unblock.
3. #1464 is one click whenever @wkozaczuk returns.
