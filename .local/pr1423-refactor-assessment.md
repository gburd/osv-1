# PR #1423 refactor assessment: "move patch files into regular source files"

Assessment date: 2026-08-13. Upstream master: af96db0f7 (unchanged).
Branch: pr/openzfs-draft @ d743cc8bd (worktree .local/worktrees/openzfs-1423).

## What wkozaczuk is asking for

From his 2026-07-24 inline review and 2026-08-02 + 2026-08-07 comments:

> only 15 files from the original openzfs 2.4.2 get modified ... most of the
> changes to make openzfs work are in new files. So I wonder if instead of these
> 27 patch files we should somehow add these new files *as is* and have only a
> single patch for these 15 files. I think it may be easier to maintain and
> understand ... I would also love to move most of what is now the patch files
> into the regular source files as I described above.

He is right about the shape of the delta. Measured on the current series (31 patches):

| bucket | patches | content |
|---|---|---|
| brand-new OSv files | 0001-0004 (+ a few in 0008/0020) | ~114 new files under `module/os/osv/`, `lib/*/os/osv/`, `include/os/osv/`, `cmd/*/os/osv/` |
| edits to upstream OpenZFS files | 0005-0031 | ~15 upstream files, ~382 lines total |

So ~90% of the patch *bytes* (0001 alone is 151 KB) is the creation of files that
do not exist in upstream OpenZFS at all. Only ~15 files are genuinely *modified*.

## The design tension (real, but resolvable)

Current design (what he approved earlier in this same PR):
- `modules/open_zfs/openzfs` is a submodule pinned to **pristine upstream**
  `github.com/openzfs/zfs @ zfs-2.4.3` (`.gitmodules ignore = dirty`).
- ALL OSv changes -- both new files and upstream edits -- are a git patch series
  in `modules/open_zfs/patches/`, applied at build time (Makefile ~line 60,
  `git -C .../openzfs apply ... && touch .osv-patches-applied`).
- Net effect: no OpenZFS fork; the delta is a rebasable patch stack.

The friction with "add the new files as-is":
- The new OSv files currently land **inside the submodule working tree**
  (`modules/open_zfs/openzfs/module/os/osv/...`). You cannot track files that
  live inside a submodule's directory in the *parent* repo -- git treats the
  submodule as an opaque gitlink. So "commit them as-is" is not a no-op move;
  it requires **relocating them out of the submodule tree** into a
  parent-repo-owned directory, e.g. `modules/open_zfs/osv/` (a real,
  parent-tracked source tree), and teaching the OpenZFS build to compile from
  both the submodule (upstream sources) and that sibling OSv tree.

This is exactly how OpenZFS upstream is itself organized: the per-platform code
lives under `module/os/<platform>/` and `lib/*/os/<platform>/` and
`include/os/<platform>/`. OpenZFS's own build (its .mk / CMake) already selects
`os/linux` vs `os/freebsd` by a platform variable. So the clean end-state is:

  modules/open_zfs/
    openzfs/            <- submodule, pristine upstream, NEVER edited
    osv/                <- NEW: parent-tracked OSv platform tree (was patches 0001-0004),
                           mirrors upstream's os/osv/ layout
    patches/            <- SHRINKS to ~1 patch: the ~15 genuine upstream-file edits
    open_zfs_sources.mk <- add -I .../osv/include and the osv/ object list

Build wiring: the OpenZFS object-list .mk already enumerates the sources it
compiles; point the `os/osv` entries at `modules/open_zfs/osv/...` instead of
`modules/open_zfs/openzfs/module/os/osv/...`. The 15-file upstream edit-patch
still applies to the submodule at build time (or, better, is small enough to
carry as a handful of `-D`/wrapper shims + a tiny patch).

## Verdict: doable, NOT a mechanical move, and it IMPROVES the design

- It does **not** conflict with the "no OpenZFS fork / submodule stays pristine"
  principle -- it *strengthens* it: after the move, the submodule tree is touched
  by exactly ONE small patch (the 15 upstream edits), and the OSv platform code
  is normal reviewable source in the parent repo, diffable and greppable without
  applying a 20k-line patch stack.
- It is **not** a `git mv` one-liner. The files physically live inside the
  submodule today; moving them out means: (1) extract the new-file content from
  0001-0004 into `modules/open_zfs/osv/`, (2) rewrite the include/object paths in
  `open_zfs_sources.mk`, (3) rebuild the remaining ~15-file edits as one squashed
  patch, (4) re-validate both `conf_zfs=bsd` (unaffected) and `conf_zfs=openzfs`
  (must still boot + mount + pass the ZFS test subset), on a KVM host.
- Risk: medium. The move is mechanical per-file but the build-path rewiring and
  the include-search-path (`-I modules/open_zfs/osv/include/os/osv/...`) must
  exactly reproduce what the patched-in layout produced, or OpenZFS TUs won't
  find their platform headers. Needs a full openzfs image build + boot to prove.

## Recommended response (do NOT force the big change blind)

This is the keystone blocked feature and the move needs a KVM host to validate.
The right move for the maintenance agent is to:
1. AGREE with the direction (it is better) and confirm the concrete end-state
   layout above so wkozaczuk and I are aligned before I move 114 files.
2. Flag the one non-obvious constraint (files inside a submodule can't be
   parent-tracked, so it's a relocate-out-of-submodule + build-rewire, not a
   git-mv) so he knows why it wasn't already "as-is".
3. Tie it to the forward-port already promised on 2026-08-07 (the branch base
   predates merged tests; it needs a real rebase onto current master anyway).
   Do the restructure AS PART OF that forward-port, in one pass, then re-validate.
4. Also fold in his other pre-merge asks from 2026-08-02: un-set the DRAFT/BLOCKED
   banner if it no longer applies, squash the 27 commits to one, rename
   `tst-zfs-db-sim.cc` -> `misc-zfs-db-sim.cc` (long-running stress), and
   document/open an issue for the known openzfs test gaps (tst-fallocate,
   tst-fs-link, tst-utimensat, tst-utimes, tst-zfs-mount).

Not implementing the 114-file move in this maintenance pass: it requires a full
openzfs KVM build+boot validation cycle and a careful build-path rewire that
must not be done unvalidated on the keystone feature. Drafted a precise
alignment response instead (below), so the next focused session can execute the
move against a confirmed target layout.

## EXECUTED 2026-08-15 (maintenance sweep, wkozaczuk approved the layout 2026-08-14)

Maintainer reply 2026-08-14: "I agree with your proposal ... I agree with the
layout of modules/open_zfs/. We also need to decide what to do with the unit
tests that currently fail with open-zfs and one long-running tst-* test." =>
go-ahead. Did the mechanical restructure on a STAGING branch (not the PR):

- Branch: wip/openzfs-restructure @ 7940379c0 (off pr/openzfs-draft d743cc8bd),
  G-signed, pushed to origin (codeberg fork). Worktree
  .local/worktrees/openzfs-restructure. NOT pushed to the PR head branch.
- Cloned the openzfs submodule at the pinned 83020cf8, applied the full 31-patch
  series clean (rc=0) to materialize the platform files, then:
  - Relocated 117 OSv-authored files (module/os/osv 26, include/os/osv 61,
    lib/*/os/osv 14, cmd/*/os/osv 3, module/zfs/zfs_initialize_osv.c 1,
    lib/libspl/include/os/osv 12) into modules/open_zfs/osv/<same-rel-path>,
    byte-identical (modulo em-dash cleanup: 57 em/box chars in comments -> ascii).
  - Regenerated the patch series 31 -> 1: modules/open_zfs/patches/
    0001-osv-openzfs-upstream-file-edits.patch (407 lines) = exactly the 15
    edited upstream files, zero new-file hunks.
  - Rewired the build: new OZFS_OSV := modules/open_zfs/osv in the top-level
    Makefile (34 os/osv refs swapped $(OZFS)->$(OZFS_OSV), os/freebsd + core
    module/zfs stay on $(OZFS)) and in open_zfs_sources.mk (24 object refs +
    2 -I include dirs + 2 -include headers + the zfs_initialize_osv -fPIC rule).
    -isystem search ORDER preserved (general libspl before os/osv), so
    #include_next override resolution is unchanged.
  - Updated the stale provenance comments in Makefile + open_zfs_sources.mk +
    module.py to point at modules/open_zfs/osv/.
  - Renamed tst-zfs-db-sim.cc -> misc-zfs-db-sim.cc (git mv), updated the
    modules/tests/Makefile manifest entry, fixed the in-file .so self-references.
- Static validation done (this host is NixOS gcc14, NOT the fedora:39 musl
  toolchain the openzfs build needs, so no local full build): every object,
  include dir, and -include header resolves to a real relocated file; makefile
  parses with conf_zfs=openzfs (stops only on missing musl/kbuild submodules,
  not on my edits); full staged diff leak-clean + em-dash-clean.
- Posted a progress comment to #1423 (issuecomment-5301075469) with the result,
  the plan to fold the restructure into the forward-port, and a proposed
  unit-test disposition (fix-if-small else documented-gap + tracking issue),
  asking for the maintainer's nod on the test-disposition split.

NOT done this session (needs the pinned fedora:39 toolchain + KVM, next focused
session): the full conf_zfs=openzfs build + boot + pool-mount validation; the
forward-port rebase onto current master; drop DRAFT banner; squash to one
commit; ZFS tests -> standalone tests += (#1469); the tracking issue for the
failing unit tests; then update the live #1423 branch.

DECISION on copyright: the 117 relocated files are a RELOCATION of existing PR
content (already carrying the PR's "Copyright (c) 2026, OSv contributors" / CDDL
convention consistent with upstream OpenZFS), not newly-authored files.
Overwriting 117 headers with a personal copyright would break the PR-wide
convention for an upstream CDDL contribution and churn review, so the existing
attribution was preserved. New-file authorship copyright applies to files
authored fresh, not to a mechanical relocate of already-attributed source.

## FINALIZED 2026-08-17 (maintainer's exact conditions met -- MERGE-READY)

wkozaczuk 2026-08-17 (+ email: he's offline on OSv til ~Nov, wants #1423 landed
now): "rename the long-running tst-zfs-db-sim.so to misc-zfs-db-sim.so and
document the gap [tst-fallocate, tst-fs-link, tst-utimensat, tst-utimes,
tst-zfs-mount]. Squash into a single commit, undraft and I will merge."

Executed exactly, nothing extra to review:
1. RENAME: already on the branch (the restructure agent did it at 7940379c);
   verified `git grep zfs-db-sim` shows only the misc- form. No double-rename.
2. GAP-DOC: concise KNOWN-FAILING-TESTS table appended to
   modules/open_zfs/FINDINGS-osv-openzfs.md (5 tests + brief why-each +
   "tracked, not regressions"). Tracking issue opened: cloudius-systems/osv#1474.
   Deliberately did NOT try to FIX the 5 tests (out of scope; maintainer accepts
   documenting the gap).
3. SQUASH: 29 commits -> 1 (174548e79, G-signed %G?=G). Squashed off the PR's
   own base cb8c7205b (soft reset + single commit), NOT rebased onto current
   master (not asked; a rebase would risk the KVM-qualified tree). VERIFIED
   build-equivalence: squashed tree = 3ff0478a3 = byte-identical to the
   qualified head 6c4c39bb6 tree + the 18-line docs gap-note ONLY (docs don't
   compile), so the earlier build+boot+pool-import+root-mount+r/w/checksum
   qualification @ 6c4c39bb6 still holds. conf_zfs=bsd byte-for-byte unchanged.
4. FORCE-PUSH (legitimate maintainer-requested history rewrite): via the
   documented .envrc opt-in (PI_ALLOW_FORCE_PUSH=1 loaded by direnv) +
   force-with-lease branch-name+SHA form:
     git push --force-with-lease=pr/openzfs-draft:6c4c39bb6 gh-fork HEAD:pr/openzfs-draft
   Result: 6c4c39bb6...174548e79 (forced update) -- ref updated IN PLACE, NOT
   delete+recreate, so PR #1423 was NOT auto-closed. Pre-push: stale-base check
   (remote still 6c4c39bb6) + leak-scan (clean, ascii-only, no em-dashes, no
   infra/acct/SG literals) passed first.
5. UNDRAFT: PR was ALREADY isDraft=false (the zfs-qual agent undrafted it on the
   ff-update); confirmed still false post-squash.
6. COMMENT: issuecomment-5312436095 posted (renamed / documented + #1474 /
   squashed to 1 / undrafted / ready; noted the sole GitHub "conflict" is a
   1-line .gitignore adjacency -- master added ext_images/, PR adds the
   !patches exception right after the same context line, both keepers -- offered
   to rebase if he prefers but left the validated tree untouched).

FINAL STATE (verified via gh): PR #1423 state=OPEN, isDraft=false,
headRefOid=174548e79, commit count=1. MERGE-READY. All four conditions met.
The keystone OpenZFS feature is ready for the maintainer to merge in one click.
