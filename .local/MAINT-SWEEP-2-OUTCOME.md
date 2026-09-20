# Maintenance sweep 2 (agent 11dee939) + operator follow-through (2026-09-14)

## Sweep findings (all verified)
- **56 open PRs** (+2 since last: #1508, #1509). ZERO genuinely-unanswered reviewer comments across all,
  both APIs walked. Only 6 have human interaction; gburd's reply is last after every one.
- **#1464 APPROVED** (maintainer to merge). **#1439 CHANGES_REQUESTED STALE** (all points answered).
- All 6 recent PRs (#1508/#1509/#1472/#1502/#1505/#1507) merge-tree CLEAN vs master, no review.
- Dependencies ALL current, zero bumps (OpenZFS 2.4.4 newest, lwext4 pin == fork tip, musl/acpica pinned).
- No new external activity (lwext4#100, osv-apps #71/#73 idle).
- **upstream == gh-fork == codeberg master == 0e34e4dc2, unmoved since 2026-08-17.**
- Correctly caught the mis-tagged m1confirm boxes (a2abench7 tag, minutes old) and LEFT them, gating
  termination on LaunchTime per my steer. 0 orphans, 0 terminations.
- /tmp: removed ~68K of THIS project's scratch; LEFT ~139G of OTHER projects' files (xtc/xbench/libdb/
  pgfts/amgettuple/solnix) - correctly hands-off on the shared host. Worktrees 14->14 (all load-bearing).
- One scope note: /scratch/gburd has prior-session OSv logs, out of the /tmp tidy scope, left untouched.

## Operator follow-through: #1447 -> #1510 (the one actionable finding)
The agent flagged that #1447's head cannot be repointed onto a base with af27ba4b7, but pr/ext4-perf-v2
already exists, is merge-tree clean, contains af27ba4b7, and carries its own measurements (N=4/M=4
device-queue-depth sweep, 1.28 GB/s knee). I verified:
- v2 apps pin reachable (no dangling-pin), head G-signed.
- The "parity" mention in v2's commit messages is a LEGIT baseline description (writes at parity, reads
  were the problem this PR fixes) - NOT the withdrawn write-parity claim from the original #1447's
  f20b91d75 (which is not in v2). So v2's history is clean.
FILED #1510 (draft, from pr/ext4-perf-v2), CLOSED #1447 with a pointer. #1510 kept draft pending a fresh
current-master re-measurement to reconfirm, but the branch is clean and ready.

## Remaining work (ranked, unchanged)
1. Merge #1502/#1503/#1504 (first non-fork-gated, all clean) - maintainer offline.
2. Merge #1464 (APPROVED) - maintainer.
3. Clear #1439 stale flag - maintainer.
4. #1455/#1456 fork composition - maintainer decision.
5. ext4 re-measure to un-draft #1510.
6. P4 PGXN - not started.
7. M1 confirmation (#1509 e2e) - IN FLIGHT (agent 0c90e588).
8. musl 1.2.x rebase; 106 private branches w/ dangling pin (harmless).

## Standing note: memory MCP unavailable
The mcp memory tools returned "not found" for this agent too (as in prior sweeps). Lessons continue to
live in .local/*.md. Re-file into memelord when it recovers.
