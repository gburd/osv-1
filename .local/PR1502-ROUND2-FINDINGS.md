# #1502 round-2 review findings (nyh + sweep 41232033) - VERIFIED, and one is a bug I INTRODUCED

## 1. LATENT BUG - double LIST_REMOVE through a stale pointer. VERIFIED IN SOURCE.
## *** ATTRIBUTION CORRECTED: it is PRE-EXISTING on master, NOT introduced by me. ***
## git diff of dentry_children_remove between upstream/master and the PR: IDENTICAL (byte-for-byte), and
## the fake-list-shares-d_link design is also on master (vfs_dentry.cc:48 and :181). So I neither added nor
## modified it - nyh's AI found a real pre-existing OSv defect while reading my PR. Report it that way
## (claiming I introduced it would be as wrong as claiming I did not).
The `fake` list and the hash chain SHARE the `d_link` field:
  vfs_dentry.cc:48   static LIST_HEAD(fake, dentry) fake;
  dentry_remove(dp): LIST_REMOVE(dp, d_link) from the hash, then LIST_INSERT_HEAD(&fake, dp, d_link)
  drele(dp):         LIST_REMOVE(dp, d_link)            <- expects dp to still be on hash-or-fake
MY dentry_children_remove(parent) (added in the dentry_move commit) does, for EVERY child:
  LIST_FOREACH(entry, &dp->d_children, d_children_link) { LIST_REMOVE(entry, d_link); }
=> if a child is on the FAKE list (already dentry_remove()d but still referenced), the loop unlinks it from
   `fake` via d_link, and the later drele() LIST_REMOVEs it a SECOND time -> writes through a stale pointer.
   Silent list corruption. nyh is right that the hazard is real; it is PRE-EXISTING (see attribution above).
FIX DIRECTION: dentry_children_remove must not blindly LIST_REMOVE a child's d_link. Options: (a) only
remove children that are actually on the hash chain (track/flag hash membership), (b) give the fake list its
own link field so d_link membership is unambiguous, (c) do not touch children's d_link at all in
dentry_move() - re-hash them instead, which is what the rename actually needs. (c) is probably the minimal
correct change: dentry_move is re-parenting, so children need their hash keys updated, not to be unlinked.

## 2. DEBUG_VFS NEVER BUILDS. VERIFIED: fs/vfs/vfs.h:50 is `/* #define DEBUG_VFS 1 */` (commented out) and
## DEBUG_VFS is defined NOWHERE in conf/ or the Makefile, and there is no CI for it.
=> the vn_lock() ordering ASSERTION I described as the "teeth" of the rule NEVER COMPILES in a normal build.
   My commit message claims it "fires on the unfixed drele()" - unverifiable as shipped. Either (a) say
   plainly it only builds under a manually-enabled DEBUG_VFS, or (b) make the check always-on but cheap
   (owned() is a single relaxed load + compare, so an unconditional ASSERT is affordable), or (c) drop the
   claim. (b) is the most honest and most useful - it makes the rule enforceable in real builds.

## 3. "14 sites" is really 7. VERIFIED by count. A sloppy number in my own description; correct it.

## 4. The leaf-lock / reachability / test-header / observation-attribution charges: ALREADY FIXED in
## c7ab5929e (see .local/PR1502-REVIEW-BODY-ANALYSIS.md) and replied to (comment 5750804145).

## #1508: nyh questions whether physio() should EXIST at all. Sweep's caller audit: ZERO callers in master;
## the only caller is #1424's driver (2 lines). Our #1424 justification is stale by our own c8c153047.
## => DELETION is likely the right answer, not fixing it. That is a bigger, cleaner change than my +2/-37.
## Note I already added the bounds check (75bb43bf6), which is correct-but-possibly-moot if the function goes.

## SWEEP METHODOLOGY FIX (banked, high value): while a review is PENDING its comments are invisible to
## pulls/<n>/comments, pulls/<n>/reviews, GraphQL reviewThreads, the timeline, AND notifications;
## pulls/comments/<id> returns 404. ONLY the events API shows them. The standard scan returns a FALSE NULL.
## That single check was the difference between "0 new activity" and finding the whole review.

## ALSO from the sweep: GitHub's CONFLICTING flag is STALE on #1449 and #1440 (both merge clean now), so
## only 6 PRs genuinely conflict, not 8. notes/pg-campaign-record refreshed 1398cc43e -> 5972d9241 (both
## mirrors), deliberately EXCLUDING the 38 live .local/iouring/* files to avoid banking a moving target.

## ALL ROUND-2 POINTS NOW ANSWERED (2026-09-20):
 - #1502 comment 5750841798: DEBUG_VFS-never-builds (offered to make the owned() check unconditional since
   it is now a single relaxed load + compare, or delete the claim - asked his preference); "14 sites"->7
   corrected; the fake-list double-LIST_REMOVE acknowledged as REAL but shown PRE-EXISTING (byte-identical
   dentry_children_remove on master + the fake/d_link sharing on master), with a proposed minimal fix (give
   the fake list its OWN link field rather than teaching the loop to guess) and a direct question: file it
   as its own PR against master, or fold it in here?
 - #1508 comment 5750850279: verified his deeper question. Our 3-arg physio() has NO in-tree caller - the
   zvol.c:1429/:1476 hits are the OLD 6-arg BSD form in a file that is NOT BUILT (we compile
   $(OPENZFS)/module/zfs/zvol.o), and vdev_disk_physio is a different function. Only consumer is #1424's
   driver (2 lines) and our justification is stale per c8c153047. => I RECOMMENDED DELETION (drop physio()
   + its include/osv/device.h decl, have #1424 call bdev_strategy_rw() directly) over repairing a public
   entry point with no users, and asked him to choose.
## Both replies ask a QUESTION rather than unilaterally deciding, because both are scope calls that belong
## to the maintainer, not to me.

## SWEEP ALSO DELIVERED: notes/pg-campaign-record 1398cc43e -> 5972d9241 on BOTH mirrors (G-signed,
## fast-forward), deliberately EXCLUDING the 38 live .local/iouring/* files (a moving target mid-run). Built
## with GIT_INDEX_FILE plumbing so my 118 dirty working-tree paths were never touched - good technique.
## GitHub's CONFLICTING flag is STALE on #1449 and #1440 (both merge clean now) => only 6 genuinely conflict.
## /tmp/rxpool-wt flagged as probably-spent, left for my call. EC2 clean, 0 orphans, iouring boxes untouched.
