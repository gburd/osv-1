# Correction: `git apply` is NOT atomic, and the real bug is worse than I said

2026-09-07. The maintenance agent (118b8e81) corrected two errors in my brief. Both
verified independently.

## Correction 1: the malformed-0031 bug is NOT upstream-facing

I framed `modules/open_zfs/patches/0031`'s malformed hunk header as an upstream bug
worth a PR. Wrong. Verified:

    git ls-tree --name-only upstream/master modules/open_zfs/patches/
    -> modules/open_zfs/patches/0001-osv-openzfs-upstream-file-edits.patch

`upstream/master` and all 42 open PR head branches carry exactly ONE squashed patch,
which applies cleanly. The 32-patch series (with the malformed 0031/0032) exists
only on private local branches (baseB, pr/openzfs-aarch64, corruptor-fix-*). So the
malformed hunk is real but affects no PR and no upstream code - local-only, not
PR-able as I described.

## Correction 2: `git apply` is not atomic, and my premise was false

I asserted that because `git apply` is atomic, a single bad patch makes all 32 fail
cleanly. The agent said no: on the 32-patch series, 0001..0030 applied and left 26
files dirty before 0031 failed.

I reproduced it in a scratch repo and it is worse than either of us said:

    git init; commit f.txt
    p1.patch = valid hunk
    p2.patch = bogus hunk (@@ -99,3 @@ against a 3-line file)
    git apply p1.patch p2.patch
      -> "error: patch failed: f.txt:99" / "patch does not apply"
      -> exit status 0
      -> p1's change LANDED (grep GOOD f.txt == 1)

**Partial apply AND exit 0.** So the `&& touch stamp` in the Makefile can fire on a
half-applied tree.

## The actual PR-able bug (on master, Makefile line 63)

    openzfs_patch_stamp := modules/open_zfs/openzfs/.osv-patches-applied
    $(shell if [ -d modules/open_zfs/openzfs/module ] && [ ! -f $(openzfs_patch_stamp) ]; then \
        git -C modules/open_zfs/openzfs apply --whitespace=nowarn $(addprefix ../patches/,...) 2>/dev/null \
        && touch $(openzfs_patch_stamp); fi)

Four properties that compound into a silent, sticky broken build:
- (a) `2>/dev/null` hides the diagnostic entirely
- (b) multi-patch `git apply` can partially apply AND exit 0, so `&&` does not protect
- (c) it runs inside `$(shell ...)`, whose return value make ignores
- (d) net effect: a half-patched OpenZFS tree, STAMPED AS DONE (so the breakage
      persists across rebuilds), producing a guest that dies at "trying to execute
      null pointer" in `taskqueue_thread_loop` with zero build-time indication

Today master carries only one patch, so the partial-apply window is narrow - but the
guard is precisely what makes adding future patches safe, which is the PR's
motivation. Fix shape: stop discarding stderr, check the result explicitly, fail the
build loudly, and only stamp on genuine success.

## Why this matters beyond the fix

This is the second time a "silent failure that stamps success" has cost real time
(the first: `ext_fsync` being `vop_nullop` made lwext4 look broken). A build step
that can half-succeed and mark itself complete is worse than one that fails, because
it produces confident wrong measurements. Worth watching for the same pattern
elsewhere.

## Process note

I stated a false premise ("git apply is atomic") in an agent brief, and the agent
tested it rather than accepting it. That is the behaviour I want. The failure mode to
guard against is an agent that quietly works around a wrong instruction instead of
correcting it - this one did the opposite, twice, in one report.
