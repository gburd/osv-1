# Maintenance round 9 (agent 7ffcfa67) + my follow-through

2026-09-08. Five of my premises corrected, two new unpushed-work discoveries, 28->15
worktrees with zero loss, and one publicly-broken PR fixed and empirically verified.

## Premise corrections
| my claim | verdict |
|---|---|
| dangling pin = "x86 lineage, 2 branches" | **104 branches** |
| `wip/pg-v26-faultfix` exists locally | **No**, `gh-fork` only |
| 9 PRs CONFLICTING | **#1449 and #1440 are CLEAN** |
| "every published benchmark unreproducible" | **too strong**, two distinct harms |
| no OpenZFS 2.4.5 | **confirmed** (2.4.99 is dev) |

The #1449/#1440 correction is the best of these because the agent **proved the mechanism
rather than just the result**: re-running the same merges from a worktree at `d7c3cb81a~1`
(before the union driver existed) makes both falsely conflict; with the driver present both
are clean. That is GitHub's caching bug reproduced on demand, and it is why merge-tree from a
master worktree is the only authoritative check.

## Two discoveries I did not ask for
- **`ena-rss` had 2 modified source files** (`ena.cc`, `ena_datapath.cc`), not the "0 dirty"
  my survey reported. My dirty-count excluded submodule noise and missed these. **Preserved.**
- **LAN host `arnold` holds a 787M OSv tree, branch `claude`, commit `561cd330`, 18 dirty
  files, touched today. `561cd330` exists on NO other ref anywhere.** Unpushed work on another
  machine. Correctly touched nothing. (`floki` is this host.) I need to decide whether to
  preserve or land that; noting it rather than acting.

## Reviewer state: nothing owed, verified programmatically
A reply-ID thread walk across all 47 PRs and both comment APIs found **every** human thread
from `nyh`/`wkozaczuk` has a `gburd` reply after the last human message. #1464's inline
comment was answered as a top-level comment.

**#1439**: `nyh`'s only ask (squash) is satisfied - `git log upstream/master..ac1e4c560` = 1
commit. But the agent caught **an inconsistency in our own replies**: on 2026-07-21 we said
SIGKILL/SIGSTOP are "rejected with EINVAL", contradicting an earlier correct reply saying they
are filtered. I verified at the call site (`libc/signalfd.cc:249-255`: `sigdelset(&effective,
SIGKILL); sigdelset(&effective, SIGSTOP);` with no EINVAL) - **the earlier reply was right and
the later one misstated our own code**. Posted a correction (issuecomment-5588253248). Telling
a reviewer the wrong thing about our own patch is worse than saying nothing.

**#1447**: premise confirmed exactly - `pr/ext4-perf` does NOT contain `af27ba4b7` and
conflicts in 3 files; `pr/ext4-perf-v2` does and merges clean. I checked whether the head could
be fast-forwarded onto v2: **it cannot** - they are divergent rebases, not ancestor/descendant,
so a move would need a force-push (blocked). Posted a status note (issuecomment-5588265758)
explaining the situation and keeping it draft to preserve review context, rather than closing.

## #1458 fixed, and verified in BOTH directions
The agent built on the **published** head `dad77b7f` rather than the local branch, which had
diverged 1 commit ahead - publishing that would have leaked unrelated work. Commit `b01994d04`,
`%G?`=G, fast-forward push, no force. Then it proved the fix instead of assuming:

    dangling 57c60798 -> fatal: remote error: upload-pack: not our ref   (RC=128)
    b38b99cd          -> branch b38b99cd -> FETCH_HEAD                  (RC=0)
    fresh clone + git submodule update --init apps -> checked out b38b99cd, RC=0

Its one worry: that `b38b99cd` is reachable only as `refs/pull/73/head` and would die if that
PR were deleted. **I checked and this is unfounded** - `git ls-remote` shows
`b38b99cd -> refs/heads/wip/postgres18-musl-demo`, a real branch. The fix is durable.

## Deps
Every pin re-verified live. OpenZFS **2.4.4 is newest stable**; no conflict risk since upstream
carries 1 patch file, not our 29. **Filed outside cloudius-systems/osv: exactly one thing
ever** - `gkostka/lwext4#100`, still OPEN with **0 comments** since filing. Nothing ever filed
to openzfs/zfs, qemu, or musl. **New finding: `lwext4` is cloned unpinned at `--depth 1`, so
ext4 builds are not reproducible across time.** That is a real reproducibility hole in the same
family as the dangling submodule pin.

## Tidy: 28 -> 15 worktrees, zero work lost
I verified every preserved branch still resolves (`rxpool-fix`, `integ/pg-fork-arena`,
`pr/ipv6-forward-port`, `wip/aarch64-p2`, `pr/numa-discovery`, and the 1-unpushed set) - all OK.
Correctly kept both **detached** worktrees (`forksym`, `scrub-aarch64`), since a detached HEAD
is the only thing keeping those commits alive. `/tmp` cleaned, `/tmp/gitsign` kept. It never
used recursive-force deletion, never `git add -A`, never a bare force-push.

**EC2: 0 orphans**, verified by checking all **28** recorded campaign instance IDs individually.
All 6 unattached volumes and 11 snapshots belong to `solnix` - including the "untagged" one,
which actually carries `Agent=solnix-a6uart`. Deleted nothing.

## Prophylactic proposed, not installed
A pre-push submodule-reachability check. Note the naive local version
(`git -C <path> cat-file -e`) **false-positives** on shallow submodules
(`modules/open_zfs/openzfs`); only remote reachability is authoritative. Draft at
`/tmp/pre-push-proposal.sh`.

## Open for my judgement
1. **#1476** asserts "collapses the per-request halt/wake round-trip" and "no low-concurrency
   regression" with **zero numbers**. Either measure it or reframe as a mechanism/tunable PR.
2. The **6 active branches** carrying the dangling pin (`wip/fork-clone-scan`, `v26fault`,
   `wip/pg-rx-directwake`, `rxpool-fix`, `integ/pg-fork-arena`, `v26plus`) - fix deliberately
   so future benchmark runs are reproducible.
3. **`arnold`'s unpushed `claude` branch** - preserve or land.
4. **Pin `lwext4`** to a specific commit.

## My follow-through on the four open items (2026-09-08)

**1. #1476 reframed, DONE.** Found we DID have measured data (`.local/IDLE-SPIN-RECONCILE.md`)
reconciling two contradictory runs. The honest story is better than either raw number:

    qemu 8.1.3 host:  halt_exits/s 48975 -> 434    (99% collapse) and tps rose
    later qemu host:  halt_exits/s 57692 -> 58084  (unchanged)    and tps flat
                      with halt_poll_ok already ~46k of ~58k halts

Both runs are internally consistent: **tps moved if and only if halts collapsed.** Two
mechanisms race to catch the imminent request, the guest's idle spin and the host's KVM
adaptive halt-poll, and whichever fires first wins. So the knob reduces per-request halt
VM-exits on hosts whose hypervisor is not already halt-polling those wakes, and is a pure
CPU-burn no-op where it is. Rewrote the Effect section with those numbers, and **explicitly
retracted** the old "collapses the per-request halt/wake round-trip" / "no low-concurrency
regression" wording, quoting it as what was wrong. Kept DRAFT. Verified the old phrases now
survive only inside the retraction sentence.

Notable: the reconciliation doc's own recommendation was "reframe, do not withdraw, and do NOT
chase a clean rerun" - because the result is host-halt-poll-dependent **by construction**, so a
rerun can only reproduce "sometimes +X%, sometimes null". That is a case where more measurement
would have been waste, which is unusual for this project and worth remembering.

**2. lwext4 pinned, PR #1500 opened.** `modules/lwext4/Makefile` used
`git clone --depth 1` with no pin, so two builds of the same OSv tree could link different
lwext4 revisions with no record of which. Pinned to the fork's current HEAD
`6f6d8f7c509da696e71e80cc5a59abfc48e4971b` (2025-07-04), kept overridable via
`make lwext4_commit=<sha>`, and dropped `--depth 1` since a shallow clone cannot check out an
arbitrary commit. **Verified by actually running the clone+checkout**, not by assuming the SHA
resolves. Same reproducibility family as the dangling submodule pin, and it means the ext4
re-measurement (#1447) will finally be attributable to a known lwext4 revision.

**3-4. Still open:** the 6 active branches carrying the dangling apps pin, and `arnold`'s
unpushed `claude` branch (`561cd330`, on no other ref anywhere).
