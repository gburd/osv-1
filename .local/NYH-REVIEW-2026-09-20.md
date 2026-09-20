# @nyh's review, 2026-09-20 (first activity in 34 days) - ALL CONCERNS ADDRESSED

## Process lesson (banked as a standing sweep rule)
His #1502 comments arrived as a PENDING/unsubmitted review: visible ONLY via the events API
(PullRequestReviewCommentEvent), 404 on pulls/comments/<id>, absent from pulls/1502/comments and GraphQL
reviewThreads. The standard "scan for new reviewer comments" silently returns a FALSE NULL during an
in-progress review. ALWAYS also check the events API. This nearly caused us to report "0 new comments" on
the day the maintainer came back. Second lesson: I replied to #1508 after seeing 2 of 3 comments - the
third (15:16) had not surfaced yet. RE-FETCH after a review is submitted before claiming all points are
addressed.

## #1502 vfs dentry AB-BA (review 5260826718, CHANGES_REQUESTED 15:02Z) - FIXED in d6166ed3a
1. Duplicate extern decl -> DELETED (vfs.h:167 already declares it; this file includes vfs.h).
2. "Don't our locks already have a depth?" -> YES, he was right and it is better than what I wrote.
   dentry_hash_lock IS a `mutex`; core/lfmutex.cc:308 mutex::owned() == (owner == current thread), exactly
   my predicate. vfs_dentry_hash_lock_held() is now `return dentry_hash_lock.owned();`. Deleted the
   __thread counter, both enter/exit helpers, the non-debug no-op stubs, and every paired call site:
   -18/+6. ALSO more robust: a future call site forgetting the pairing would silently desync a counter;
   owned() cannot drift.
3. "Fix WITH_LOCK to do the enter/exit?" -> moot in the best way: with owned() there is no hook to place,
   so WITH_LOCK is untouched.
   VERIFIED SAFE: both the definition and the vn_lock() ASSERT call site (vfs_vnode.cc:153) remain under
   #ifdef DEBUG_VFS, as does vfs.h's declaration - so no link breakage in non-debug builds. Semantics
   unchanged (owned() is per-thread, as the counter was).

## #1508 physio per-iovec (CHANGES_REQUESTED 15:18Z, 3 comments) - FIXED in 1b9b5add8 + 75bb43bf6
1. (15:12) "physio() is character-for-character bdev_strategy_rw()" -> COLLAPSED to delegate. +2/-37 vs
   master. His sharper sub-point: my loop kept the bare `uio_resid > 0` while bdev_strategy_rw has
   `uio_resid > 0 && uio_iovcnt > 0` - so once my `continue` stopped the hang, a resid/iovec-list
   disagreement would walk off the array end. "Trading a hang for an OOB read is a step sideways" - correct.
   Delegating fixes it by construction.
2. (15:09) "avoid history lessons/changelogs in comments" -> the 18-line block explaining why the OLD code
   was wrong is GONE with the loop it described. Taken as a GENERAL note, not just this instance: a comment
   should explain why surprising code is CORRECT; the archaeology belongs in the commit message.
3. (15:16) "no bounds check - bdev_read/bdev_write both reject uio_offset + uio_resid > dev->size" -> ADDED
   in the same order as the other two entry points. Matters more because #1424 makes physio() a real
   device I/O entry point. (I had missed this one in my first reply and said so.)

## Replies posted: #1502 comment 5750714474; #1508 comments 5750717459 + 5750736049 (the third point).
## Both PR heads updated: #1502 d6166ed3a, #1508 75bb43bf6. Both still CHANGES_REQUESTED pending his re-look.
