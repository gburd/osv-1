# Re-pin commands for the dangling `apps` gitlink 57c6079 (NOT EXECUTED)

Verified 2026-09-11. The dangling pin `57c607984393901ce556a75f81ea40f7c469d1f3`
exists on **101** refs in this repo. It is unreachable on both remotes:

    $ git fetch --depth=1 https://github.com/gburd/osv-apps.git 57c607984393901ce556a75f81ea40f7c469d1f3
    fatal: remote error: upload-pack: not our ref 57c607984393901ce556a75f81ea40f7c4

The good pin is **5cb19033555d6d4370da905965016f0adb81e515**, reachable on both
`gburd/osv-apps` and `cloudius-systems/osv-apps`, carrying the `.PHONY: module
build` fix that stops the build silently omitting PostgreSQL.

## The 6 active branches, all confirmed carrying the dangling pin

    wip/fork-clone-scan     head=65279b938   apps=57c60798
    v26fault                head=73a332f26   apps=57c60798
    wip/pg-rx-directwake    head=b318d8502   apps=57c60798   <- the checked-out branch
    rxpool-fix              head=859210d54   apps=57c60798
    integ/pg-fork-arena     head=858dd78f2   apps=57c60798
    v26plus                 head=9b3207e5c   apps=57c60798

## Commands (review before running; nothing here has been run)

Run from a scratch worktree, one branch at a time, so a dirty main worktree is
never involved. `wip/pg-rx-directwake` is currently checked out in
`/home/gburd/ws/osv` with 32 dirty files, so do that one last and by hand.

    cd /home/gburd/ws/osv
    git worktree add /tmp/repin-wt --detach upstream/master

    for b in wip/fork-clone-scan v26fault rxpool-fix integ/pg-fork-arena v26plus; do
      git -C /tmp/repin-wt checkout -q "$b" || break
      git -C /tmp/repin-wt update-index --cacheinfo \
          160000,5cb19033555d6d4370da905965016f0adb81e515,apps
      git -C /tmp/repin-wt commit -q -S -m "apps: re-pin to 5cb1903 so the build cannot silently omit PostgreSQL

The recorded apps gitlink was 57c607984393901ce556a75f81ea40f7c469d1f3, a commit
that exists in no repository:

    fatal: remote error: upload-pack: not our ref 57c60798...

so 'git submodule update' cannot initialize the tree and any build from this
branch is unreproducible. 5cb1903 is reachable on both remotes and carries the
'.PHONY: module build' fix, without which make skips build.sh and produces a
PostgreSQL-free image while exiting 0."
      git -C /tmp/repin-wt log -1 --format='%H %G? %s'   # expect %G? == G
    done

Then verify every one before any push:

    for b in wip/fork-clone-scan v26fault rxpool-fix integ/pg-fork-arena v26plus; do
      printf '%-24s %s\n' "$b" "$(git rev-parse "$b:apps")"   # expect 5cb19033...
    done

## Pushing is deliberately NOT scripted here

Each of these is a private branch, so the push is `git push gh-fork <b>` with no
force needed (the re-pin is a new commit on top, a strict fast-forward). **Do not
push without deciding branch by branch** whether the branch is still wanted: 5 of
these 6 have unpushed commits and two have large dirty trees, so a push changes
what a future bisect sees.

## The other ~95 refs

The remaining refs carrying `57c6079` are historical and inactive. Re-pinning
them rewrites history for no benefit: nothing builds from them. Leave them, and
rely on the pre-push hook below to stop the class recurring.

## Pre-push hook: RECOMMENDED, NOT INSTALLED

`/tmp/pre-push-proposal.sh` is correct as drafted and is worth installing:

    cp /tmp/pre-push-proposal.sh .git/hooks/pre-push && chmod +x .git/hooks/pre-push

Two things verified about it on 2026-09-11:

1. **It does not use the naive local check.** It uses `git ls-remote` plus a
   `git fetch --depth 1` fallback, i.e. remote reachability, which is the only
   authoritative form. A `git -C <path> cat-file -e` version would false-positive.
2. **That false positive is real, not theoretical.** `modules/open_zfs/openzfs`
   is a shallow submodule (`--is-shallow-repository` -> `true`) and its
   legitimate recorded pin `6330a45b0` **fails** `cat-file -e` locally. A naive
   hook would block every push.

Dry-run of its enumeration step against the current HEAD lists all 8 submodules
and would flag exactly the one bad pin (`apps 57c60798`), so it has teeth.

It stays uninstalled pending your go-ahead: it is untracked and repo-local, so
installing it changes no tracked file.
