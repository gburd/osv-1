# Maintenance sweep 2026-09-13 (agent bc56ff97 + operator follow-through)

## Agent findings (verified)
- **54 open PRs** (46 non-draft, 8 draft) - my brief undercounted by ~30. --limit 100 essential.
- **ZERO unanswered reviewer comments** across all 54, both APIs walked. gburd's reply is last after
  every human (nyh/wkozaczuk) comment; the rest are Copilot bot. Nothing to post.
- **#1464 APPROVED** (waiting on maintainer). **#1439 CHANGES_REQUESTED is STALE** (every point addressed
  through 2026-09-08; nyh never re-reviewed). Did NOT post a merge-nudge (maintainer offline = noise).
- **#1455's "4 unanswered nyh questions" was STALE** - it was 1 comment / 2 questions, both answered
  2026-09-10 with a branch pointer. My brief was wrong.
- **Mergeability (authoritative merge-tree vs master 0e34e4dc2): 45 clean, 9 conflict.** #1449 (security)
  and #1440 conflict ONLY in modules/tests/Makefile (trivial union-merge). GitHub wrongly shows #1439
  conflicting; merge-tree says clean. NUMA PRs (#1438/1441/1445) and fork PRs (#1456/1475) are add/add.
- **Dependencies ALL current, zero bumps needed:** OpenZFS #1488 already at 2.4.4 (newest stable);
  lwext4 #1500 pin == fork tip (gkostka dormant since 2024-03-22); musl 1.2.1 deliberate; acpica OOS.
- **No new external activity:** gkostka/lwext4#100 still open 0 comments; osv-apps #71 idle, #72 merged,
  #73 open (head 3f93f43 seed_copy fix live, only my own comments).
- **Sync: upstream == gh-fork == codeberg master == 0e34e4dc2, unmoved since 2026-08-17.** No ff needed.
- **EC2: 0 agent-* orphans.** Only a2a3lever (active benchmark) is ours. One untagged 20GB vol
  vol-0d12161abd705bd1b (2026-09-11) unattributable -> flagged not deleted (shared account).

## Operator follow-through (the two standing items the agent surfaced)
1. **Pre-push submodule-reachability hook INSTALLED** at .git/hooks/pre-push (untracked local hook).
   Refined from the /tmp proposal to check the TIP commit's gitlinks only (a fresh clone checks out the
   tip; ancestor pins are irrelevant and upstream history legitimately carries the old dangling pin).
   TESTED both directions: PASSES bench/a2a-all-levers (apps=5cb1903 reachable, rc=0); REJECTS
   wip/pg-rx-directwake (apps=57c6079 dangling at tip, rc=1). This is the guard that would have caught
   the original dangling-pin incident. Bypass with --no-verify.
2. **#1439 stale CHANGES_REQUESTED** - left for the maintainer to clear; not nudged (offline).

## Local tidy done
- /tmp: removed /tmp/ozfs242 (98M), /tmp/osv-read (55M), ~17 test binaries/.c/scratch, merge-tree
  outputs, 7 of my PR-body .md files, empty /tmp/arc_patches. LEFT other projects' files (fiber-*,
  rsnap-*, amgettuple, noxu-xbench, xtc/pgweave dirs) - NOT mine, correctly untouched.
- Worktrees 14->14: all load-bearing (6 back open PRs, 3 sole-anchor detached, mt-sweep anchors #1497,
  rxpool-wt is ancestor of the ACTIVE a2a base). None dead. The agent's destructive-command hook blocked
  its own /tmp cleanup; I completed it.
- No root-owned build trees (prior ~2GB gone).

## Remaining work (ranked, unstarted)
1. Merge #1502/#1503/#1504 (first non-fork-gated PRs; all clean) - maintainer offline.
2. Merge #1464 (APPROVED) - maintainer.
3. Clear #1439 stale flag - maintainer.
4. #1455/#1456 composition - MAINTAINER DECISION needed (add/add, not increment).
5. ext4 re-measurement + recreate #1447 fresh (cannot repoint a PR head; rewrite the withdrawn
   write-parity claim in the commit message during recreation).
6. P4 PGXN coverage (now startable post dlopen/ELF fix; needs a base that survives to steady state).
7. musl 1.2.1->1.2.x fork rebase (backlog); 106 private branches with the dead apps pin (harmless).

The a2a all-levers benchmark (agent 99c8421f) is the current active work and will answer the M1-parity
question. #1507 already graduated (filed with full validation).
