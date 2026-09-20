# Maintenance round 6 results (2026-09-07)

Agent 118b8e81. Its highest-value output was refuting two premises - one of them
mine, twice over.

## Premises refuted

| Premise | Verdict |
|---|---|
| The malformed `0031` hunk breaks all 32 patches on a PR-able path | **Scoped wrong.** The 32-patch series exists only on private local branches; `upstream/master` and all 43 PR heads carry ONE squashed patch that applies cleanly. Not PR-able as I briefed it. |
| `git apply` exits 0 on partial apply, so `&& touch` stamps a broken tree | **False.** Direct measurement: exit 128 (corrupt hunk) / 1 (does not apply). Both of our earlier exit-0 readings were pipe artifacts. Stamp correctly NOT written, verified over 3 runs. |

The 0031/0032 hunk defects are themselves real (0031 declares `-100,6 +100,14` but
has 5 context + 10 added; 0032's hunk 2 is anchored at line 1 while the real extern
is at line 50 with non-contiguous context, so it fails even with `--recount`). They
are simply not on a shipping branch.

## #1494: two bugs, and OUR OWN PR TEXT WAS WRONG

The agent proved there are two independent defects by executing the real
`resolve.py`/`module.py`:

**Bug A - caller-order module shadowing** (this is what actually bit us):

| image list | modules loaded | libsolaris.so in usr.manifest |
|---|---|---|
| `zfs,zfs-tools` | open_zfs, zfs, zfs-tools | present |
| `open_zfs,zfs-tools` | open_zfs, zfs-tools | ABSENT |
| `open_zfs,zfs,zfs-tools` | open_zfs, zfs-tools | ABSENT |

`resolve.require()` registers `open_zfs`'s `provides=['zfs']` under the name `zfs`,
so the `zfs` placeholder - which owns the `/usr/lib/fs/libsolaris.so` manifest line -
is never imported. Same shadowing exists for `bsd_zfs`.

**Bug B - the `bootfs_dep` gap.** Real and independent. #1494 fixes **B only**.

**And #1494's description contained a materially false sentence.** It claimed
"`bootfs.manifest.skel` names `/usr/lib/fs/libsolaris.so` unconditionally, so the ZFS
library is part of bootfs for every root filesystem." I verified that is FALSE for
`fs=ramfs` - which is the very case the PR is about: `scripts/build` line 224 sets
`manifest=$OUT/usr.manifest`, so `bootfs.manifest.skel` is not used at all and the
bootfs manifest IS `usr.manifest`.

I have corrected #1494's body: it now explains the dependency in terms of ramfs using
`usr.manifest` as the bootfs manifest, and adds a clearly-labelled note documenting
Bug A (with the measured table) as a separate defect this PR does not address.

Both bugs reproduce on clean master; the patch-count question is unrelated.
Bug A still needs its own fix, in the module-resolution layer rather than in callers'
image lists.

## PR #1495 opened

`build: fail the build when the OpenZFS patch series does not apply` - one file,
+26/-3, MERGEABLE, signed and GitHub-verified, leak-clean. Written on the VERIFIED
mechanism only: no false-stamp claim, no exit-0 claim. Six behaviour cases checked,
including a new guard for an empty patch directory. Motivation stated modestly.

## Everything else

- **PR comments: zero unanswered.** All 42 open PRs checked across three APIs; our
  reply postdates the reviewer everywhere. #1464 APPROVED awaiting merge; #1439
  answered, awaiting re-review.
- **Mergeability: 37 clean / 6 conflicting**, all six on the known-real list, no
  disagreement with GitHub this round. The union driver auto-merged
  `modules/tests/Makefile` in every case, confirming the method works.
- **Deps:** no drift beyond OpenZFS 2.4.3 -> 2.4.4, which #1488 already handles.
  lwext4 fork tip is current and does not track gkostka.
- **lwext4 DO-NOT-FILE intact**, verbatim, and nothing was filed. Reproducer intact.
- **Sync:** upstream unmoved at `0e34e4dc2`. osv-apps in sync.
  `wip/postgres18-musl-demo` local now MATCHES gh-fork (no longer behind).
- **Readied: none** - correct. #1476 stays draft as directed; every behind>0 draft is
  stacked or conflicting, so no rebases.
- **Tidy:** own scratch removed; kept `/tmp/rxpool-wt` (40 unpushed), `/tmp/gitsign`,
  `/tmp/bene-*`, and another run's `maint5-*`. No dead worktree found. No
  tracked-file or `.gitignore` edits.

## EC2 discrepancy - the agent was right to refuse

It flagged `i-0476003cf35b4bc3f` (osv-tlb, m5d.metal, running) as contradicting my
"no instances running" statement, declined to reap it because it had not launched it,
and declined to SSH into another agent's box. All three calls were correct: that box
is the one I launched at 12:11Z and handed to the concurrent TLB agent, and it matches
my own dispatch record. Reaping it would have killed a live root-cause hunt.

The discrepancy was MY error - I wrote "no instances running" into the brief and then
launched a box twenty minutes later, so my brief went stale before it was read.

**Process fix worth adopting:** with concurrent sessions, "is this an orphan?" is not
answerable from tags and launch time alone. Tag boxes with the dispatching agent/task
id (an `Owner`/`AgentId` tag) so a maintenance pass can distinguish live from leaked
without touching someone else's box. Keep the "terminate only what you launched" rule
exactly as it is - it was right here.

## Score

Six PRs from this arc, all OPEN and MERGEABLE: #1490, #1491, #1492, #1493, #1494
(description now corrected), #1495.
