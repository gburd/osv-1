# CORRECTION to my own correction: git apply exits non-zero, no false stamp

2026-09-07. I wrote GIT-APPLY-NOT-ATOMIC.md claiming `git apply` can partially apply
AND exit 0, so the Makefile's `&& touch stamp` could stamp a broken tree. The
maintenance agent (118b8e81) caught that this was a MEASUREMENT ARTIFACT, and it was
right. Re-verified by me:

    git apply p1_valid p2_bogus 2>/dev/null       -> rc=1   (non-zero)
    git apply p1_valid p2_bogus 2>&1 | head -3    -> $?=0, PIPESTATUS[0]=1

My "exit 0" reading came from piping into `head` - I measured head's status, not git
apply's. The agent had made the same mistake earlier and owned it; I then repeated it
independently. Both of us were fooled by the same pipe.

Also verified: after a failed apply the stamp is NOT written (checked across
repeats), and `openzfs_patch_stamp` appears exactly 3 times in the Makefile
(definition, `[ ! -f ]` test, `touch`) and is a prerequisite of NO target.

## What is actually true

| property | verdict |
|---|---|
| (a) `2>/dev/null` discards the diagnostic entirely | TRUE |
| (b) `git apply` exits 0 on partial apply, so `&&` fires and stamps a broken tree | **FALSE** - it exits non-zero (1 here, 128 on the real 32-patch series); the stamp is correctly NOT written |
| (c) runs in `$(shell ...)`, whose status make ignores | TRUE |
| (d) leaves a silently half-patched tree | PARTLY - the tree IS left dirty (26 files on the real series), but it is NOT stamped as done |

## The accurate mechanism, and it is still a real bug

`git apply` fails correctly and the stamp is correctly withheld - but nothing
surfaces the failure (`2>/dev/null`) and nothing stops the build (`$(shell)` status
ignored), so make proceeds to COMPILE a tree that `git apply` left partially
modified. Silent wrong build; observed end state is a guest dying at "trying to
execute null pointer" in `taskqueue_thread_loop`.

Sticky-ness is real but different from what I claimed: because the stamp is absent,
every subsequent make retries the apply against the already-dirty tree, which then
fails differently ("patch does not apply"), so it stays broken until someone manually
resets the submodule. Sticky-by-retry, not sticky-by-false-stamp.

Honest motivation for the PR: master carries a single patch today, so the
partial-apply window is narrow. The guard is what makes adding future patches safe,
and it converts a silent wrong build into a loud failure. Modest, and not to be
inflated.

## Lesson (mine, twice over)

1. Never read `$?` after a pipe. Use the command directly, or `PIPESTATUS[0]`, or
   `set -o pipefail`. This invalidated a claim I had already banked as verified.
2. I "independently confirmed" the agent's earlier finding by reproducing its own
   methodological error. Independent confirmation is only independent if the METHOD
   differs, not just the operator. When confirming, vary the instrument.
3. Second time this session an agent corrected a false premise of mine (the first:
   "git apply is atomic"). Both times the correction was worth more than the task as
   briefed. That is the behaviour to keep selecting for in briefs - explicitly invite
   push-back on stated premises.
