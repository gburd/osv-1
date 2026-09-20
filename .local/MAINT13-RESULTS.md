# Maintenance round 13: a retracted claim caught in a COMMIT MESSAGE, plus 5 premise corrections

2026-09-11, agent 04d7fc08. No EC2 launched, nothing ambiguous deleted, no bare force-push.

## The find that matters: #1497 would have merged a false claim into git log permanently

Its head carried **two commits with the same subject**. `afcf5a7de`'s message asserted:

    "The placeholder keeps its copy, so the supported path is unchanged and the entry is not
     duplicated: a provider and the placeholder resolve to the same module object, so the
     manifest is contributed once."

while `3f0c4579f` **deletes** `modules/zfs/usr.manifest` - the exact opposite. And
`git merge-base --is-ancestor afcf5a7de 3f0c4579f` = YES, so **merging would have put the false claim
into `git log` forever, sitting next to the commit that disproves it.**

This is precisely the failure mode I named: the correction landed in the **body** and the **code**, but
not in the **commit message**. My earlier sweep fixed the body and repointed the head and **did not
check the message.**

Fixed and verified by me:

    head c462b0cab, ONE commit, %G? = G
    tree 5c473005500a906ac5601fb051b2b75db941648d  (new)
    tree 5c473005500a906ac5601fb051b2b75db941648d  (old 3f0c4579f)   <- BYTE-IDENTICAL
    "placeholder keeps its copy" : 0 hits    "same module object" : 0 hits
    resolver-evidence lines      : 11
    old tip preserved as tag pre-audit13-zfs-provider-manifest-3f0c4579f, pushed

A pure message fix with zero code change, and nothing lost.

## Five premise corrections
1. **Three master-eligible PRs, not four** (#1502, #1503, #1504) - verified positively: zero
   `CONF_fork`/`conf_fork`/`OSV_FORK` matches in `git diff upstream/master...<pr>` for all three.
2. **The kconfig hook is NOT a standalone upstream PR.** Master has **no `config fork` at all**:
   `git grep 'config fork' upstream/master -- conf/` exits 1, as do `conf_fork` and `CONF_fork`.
   `conf/kconfig/threads` exists on master but holds only `preempt`, `lazy_stack`,
   `lazy_stack_invariant` and stack sizes. **The plain-`bool` defect is introduced by #1455 itself**, so
   `aff774350` is a self-fix inside that series. My "may be standalone" guess was wrong.
3. **20 worktrees, not 23-24**; **7 detached, not 9** (3 sole anchors, all preserved).
4. **`/tmp/pre-push-proposal.sh` already uses the authoritative form** (`ls-remote` + `fetch --depth 1`),
   not the naive `cat-file -e` I warned about. It did confirm the false positive is real:
   `modules/open_zfs/openzfs` is shallow and its legitimate pin **fails** `cat-file -e` locally.
5. **101 refs carry the dangling pin, not ~103.**

It also **caught and corrected its own error mid-sweep**: an initial "uncommitted work in `~/ws/osv-nzf`"
report came from a `git -C` that had changed directory and hashed the main worktree's dirty file. Re-ran
correctly: **all 2168 / 2020 source blobs exist in the repo, zero unique content.**

## Reviewer state: 0 unanswered, verified programmatically
All 51 PRs across **both** comment APIs plus review bodies, inline threads keyed by `in_reply_to_id`.
Human activity exists on only 6 PRs. **#1464's previously-orphaned inline thread now has an in-thread
reply** - the prior sweep's fix held. **#1439's `CHANGES_REQUESTED` is stale review state**, not an
outstanding request: the squash ask is satisfied (1 commit, `ac1e4c560`).

## GitHub is wrong on 2 of 51
merge-tree from a worktree at `upstream/master` (so the `merge=union` driver applies): **#1440 and #1449
are CLEAN** despite GitHub saying CONFLICTING. **#1449 is a security fix** and should merge early.

## What I did with its recommendations
**Landed #1458's repin myself.** It correctly flagged that `integ/pg-fork-zfs-repinned` is a **strict
fast-forward** of #1458's head with one signed commit, so no force and no recreate is needed - unlike
#1447, where the branches are divergent rebases. Verified, pushed
(`b01994d04..d3e9e973d`), confirmed `apps = 5cb190335`, and disclosed on the PR
(issuecomment-5634226458). That removes a trap from a branch whose entire purpose is to be a reference
that others start from.

**Still open for me:** installing the pre-push hook, re-pinning the 6 active branches (with
`wip/pg-rx-directwake` by hand - 32 dirty files), and asking `nyh` to clear #1439's stale review state.

## Merge order it recommends, when the maintainer returns
    #1464 (approved) -> #1502 -> #1503 -> #1504 -> #1449 (security, false conflict) -> #1500 (zero-bit)

## Dependencies: nothing to bump, all verified
OpenZFS **2.4.4 is newest stable** (full tag list checked; `2.4.99` is a dev tag, no `2.4.5` exists).
lwext4's #1500 pin **equals the fork tip** so merging changes no bits. musl pins are exact tag pins, not
drift. acpica and kbuild are at fork tips. `master` == `upstream/master` == `0e34e4dc2`; both mirrors were
2 behind and are now synced by plain non-force push.

## arnold: prior conclusion re-verified, nothing deleted
5 unpushed commits (the "23" was the full Mar-Apr window). The Rust `crucible-osv` is **one file, 77
lines, `ENODEV` from all four entry points**, superseded by #1424's real driver. The OpenZFS work is
patch-file-based against **META 2.3.6** versus master's in-tree layer at **2.4.3**. **Nothing worth
landing; nothing deleted.**
