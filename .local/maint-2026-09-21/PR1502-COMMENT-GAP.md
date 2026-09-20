# #1502: nyh's corrections landed in the commit messages but NOT in the source comments

## STATUS: VERIFIED IN SOURCE at c7ab5929e (the current filed head). NOT pushed. Needs your call.

## The gap
`.local/PR1502-REVIEW-BODY-ANALYSIS.md` scoped the owed fixes to "commit 48fc66000's message" and
"tests/tst-dentry-lock.cc header". Both were done. The **source comments in `fs/vfs/vfs_dentry.cc`** were
never in scope, and they still carry the exact claims he disproved. Those lines are ADDED by this PR's own
diff, so they are (a) what he reads on a re-look and (b) what persists in the tree after merge.

The notes file's "ALREADY FIXED in c7ab5929e" is true of the commit messages only. That is the error to
correct in the record.

## The four residual claims (all verified present at c7ab5929e)

| # | site | text still in the tree | why it is wrong |
|---|------|------------------------|-----------------|
| 1 | `vfs_dentry.cc:67` | "dentry_hash_lock is a **leaf lock** now.  Keep it that way" | FALSE as written, and it is the precise sentence he refuted. `:207` `WITH_LOCK(dentry_hash_lock)` calls `dentry_children_remove()`, which takes `dp->d_lock` at `:172`. The commit message was corrected to "no longer calls into the vnode layer; still nests d_lock, consistently"; the comment was not. |
| 2 | `vfs_dentry.cc:187` | "dentry_hash_lock is a **leaf lock** held by every lookup" | Same false claim, second site. |
| 3 | `vfs_dentry.cc:63-64` | "observed as all vCPUs halted in do_idle with an empty wakeup mask and >1000 threads parked, while memory was plentiful" | This sits inside the AB-BA header block. It is the exact misattribution moved OUT of commit 1's message, and comment 5750804145 publicly states it belongs to commit 2 (the allocation-under-lock defect). The tree still attributes it to the inversion. |
| 4 | `vfs_dentry.cc:75` | "This **fires on the unfixed drele()** and is silent once vn_del_name() is moved out" | The DEBUG_VFS-never-builds claim conceded in comment 5750841798. `vfs.h:50` is `/* #define DEBUG_VFS 1 */`, defined nowhere else, no CI. Unverifiable as shipped. |

Confirm they are added-by-this-PR, not pre-existing:

    git diff upstream/master..c7ab5929e -- fs/vfs/vfs_dentry.cc | grep -nE '^\+.*(leaf lock|observed as all vCPU|fires on the unfixed)'
    24:+ * with nothing left runnable -- observed as all vCPUs halted in do_idle with
    27:+ * dentry_hash_lock is a leaf lock now.  Keep it that way: do not call out to
    35:+ * already hold dentry_hash_lock.  This fires on the unfixed drele() and is
    97:+    // block in the page allocator, and dentry_hash_lock is a leaf lock held

## Why it matters right now
Comment 5750804145 tells him the leaf-lock wording and the observation attribution are corrected. They are,
in the messages. If his next look is at the diff (which is where a reviewer looks), he finds the disproved
sentence still sitting in the header comment. That reads worse than never having replied: it looks like the
reply was written to the review rather than to the code. He already caught one claim-vs-reality mismatch on
this PR; a second one, in the same PR, after the correction, is the expensive kind.

## Blast radius: #1503 inherits ALL FOUR
`refs/tmp/pr1503:fs/vfs/vfs_dentry.cc`
 - `:75` "observed as all vCPUs halted in do_idle with an empty"
 - `:78` "Chain locks are leaf locks.  Keep them that way"
 - `:132` "This fires on the unfixed drele()"
 - `:308` "dentry_hash_lock is a leaf lock held"
Do not rework #1503 until #1502 settles (prior sweep's standing advice, still right), but it needs the same
comment pass when it does.

## Also: his #1508 style directive applies here
> "avoid writing history lessons or changelogs in comments. The comment ... should explain why some
> surprising code is correct - it shouldn't explain why one random mistake ... is indeed a mistake."

He called that worth applying repo-wide. The `:60-65` paragraph ("drele() used to violate exactly that: it
took dentry_hash_lock and then called vn_del_name() ...") is exactly the shape he objected to: a comment
explaining why the OLD code was wrong. The proposed patch deletes it and states the rule positively. Doing
this unprompted, in the PR he raised it on, is worth more than the diff size suggests.

## PROPOSED PATCH: `.local/maint-2026-09-21/pr-1502-comment-fixes.diff`
Comments only. Zero code change, zero behaviour change. Three hunks in `fs/vfs/vfs_dentry.cc`:
1. Header block: drop the historical "drele() used to violate" paragraph AND the misattributed observation;
   replace the false "leaf lock" claim with the accurate nesting statement (nests `d_lock`, safe because
   `d_lock` is never held while taking the hash lock, must nest nothing else).
2. DEBUG_VFS block: replace "fires on the unfixed drele()" with the honest note that it only builds under
   DEBUG_VFS, which is off by default and not in CI.
3. `dentry_move()`: "is a leaf lock held by every lookup" -> "serialises every lookup".

## WHY I DID NOT PUSH IT
1. It rewrites commit 1 of a 4-commit series under **live review**, requiring a second force-with-lease
   inside 24 hours. Not in the "safe and clearly correct" class while a reviewer is mid-conversation.
2. A **PENDING follow-up review would be invisible** to me (this sweep's own methodology rule). Force-pushing
   under an unsubmitted review can orphan his in-progress inline comments.
3. His answer to the question you already asked ("own PR or fold in?") may change the series shape anyway; if
   the `fake`-list fix folds in, the comment pass rides along in the same rewrite for free.

## RECOMMENDATION
Fold this comment pass into the NEXT rewrite of #1502, whenever his answer arrives - not as a separate
force-push. If you would rather not wait (defensible: he may look at any moment, and the wrong sentence is
what he would see), it is a clean amend of commit 1 with no code change. Either way, do NOT post another
comment about it: saying "I also fixed the comments" before the push is how the first mismatch happened.

## RECORD CORRECTION OWED
`.local/PR1502-REVIEW-BODY-ANALYSIS.md` and `.local/PR1502-ROUND2-FINDINGS.md` both assert the charges are
fully addressed in c7ab5929e. Scope that to "commit messages and the test header"; the source comments were
missed. Same lesson as the original, one level down: the fix went where the review pointed, not everywhere
the claim lived.
