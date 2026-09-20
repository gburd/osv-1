# OSv upstreaming maintenance/tidy sweep - 2026-09-18

Follow-on to the 2026-09-17b sweep (.local/maint-2026-09-17b-sweep.md). READ-heavy, report-only
where the account/ownership rules require it. Every item re-verified TODAY, not re-reported blind.

DID NOT TOUCH (in-flight, per brief):
- LIVE EC2 box i-016e19e060a57409f (osv-wakelat, Owner=agent-wakelat, m5d.metal) - another agent
  owns it, racing lava expiry. No ssh, no terminate.
- Branches/files/dirs: bench/leakhunt, bank/fork-fd-reap-leak*, bank/fork-arena-real-reclaim,
  bank/fork-arena-grow-mitigation, bank/sched-adaptive-idle-spin, core/fork_arena.cc, core/sched.cc,
  PR #1458, .local/leak2/*, .local/a2a-final/*, .local/wakelat/*.
- The working tree of this branch (wip/pg-rx-directwake) carries uncommitted core/sched.cc +
  .local/walwake/* = the LIVE adaptive-idle-spin / wakeup-latency work. NOT touched.

## HARD CONSTRAINT HONORED: AWS lava account (769093516156) expires in hours.
EC2 tidy this sweep = REPORT-ONLY. Launched ZERO boxes, terminated ZERO boxes. Confirmed
sts identity = 769093516156 (lava). Did not touch i-016e19e060a57409f.

Environment: SSH agent /run/user/1000/wezterm/agent.3913155.

## HEADLINE DELTA vs the 2026-09-17b sweep: EFFECTIVELY ZERO material change, with two NEW facts.
- upstream/master STILL 0e34e4dc2 (unmoved) -> no new conflicts.
- 0 new reviewer comments anywhere; newest human reviewer touch is still 2026-08-03.
- NO maintainer reply to the #1458 composition proposal (comment 5718101962); no reactions on it.
- Deps stable: OpenZFS 2.4.3 (2.4.4 ready+clean in #1488), lwext4 pin ready+clean in #1500.
- NEW FACT 1: the adaptive-idle-spin change is now PUSHED to gh-fork bank/sched-adaptive-idle-spin
  (tip 4bedbfa6f) by the other agent - but stacked on the fork-arena leak fixes, so NOT openable
  as-is (see Task 7). The other agent owns it + it needs its a2a-VU32 re-validation.
- NEW FACT 2: #1501 (OSV_IDLE_SPIN) is confirmed un-drafted (draft=false), MERGEABLE, and
  merge-tree CLEAN on master. Nothing more to do on it - awaiting maintainer review.

=======================================================================
## TASK 1 - PR reviewer comments/issues (all 56 open gburd PRs)
=======================================================================

Scanned ALL 56 PRs three ways (issue-comments API, pulls inline-comments API, pulls reviews API),
filtering bots (Copilot/[bot]) and gburd himself.

### FINDING: 0 new reviewer activity since 2026-09-17. Nothing to reply to or post.

Newest NON-gburd, NON-bot human activity anywhere is UNCHANGED from prior sweeps:
- issue-comments: newest = @nyh #1455 2026-08-03T12:38 (then @wkozaczuk #1463 08-01, @nyh #1439 07-15).
- inline review comments: newest = @wkozaczuk #1455 2026-08-03T14:01.
- reviews: newest = @nyh APPROVED #1464 2026-08-03T14:29.
Every post-2026-09-17 PR touch is gburd's own or the leak/wakelat agents'.

### #1458 proposal-comment reply check (explicit brief ask):
Comment 5718101962 (S1..S8 fork-generation composition proposal, author=@gburd, created
2026-09-17T16:51:49Z, unedited) has **NO reply and NO reactions**. All four #1458 issue-comments
are gburd's own (2026-08-15, 08-28, 09-11, 09-17). No maintainer has replied. Maintainer offline
since 2026-08-03.

### #1501 (newly-ready) reply check:
#1501 (draft=false, MERGEABLE) has NO reviewDecision yet and no non-gburd comments - awaiting
first review. Nothing to reply to.

### Re-checked flagged PRs TODAY:
- **#1439 signalfd (CHANGES_REQUESTED): STILL STALE.** reviewDecision=CHANGES_REQUESTED,
  mergeable=MERGEABLE, non-draft. All 8 review threads resolved=true, every one lastBy=@gburd
  (last 2026-08-01T17:09). nyh's flag never cleared; nothing substantive outstanding. Maintainer-gated.
- **#1464 disperse (APPROVED): CONFIRMED.** reviewDecision=APPROVED, mergeable=MERGEABLE, non-draft.
  6 review threads unresolved but each lastBy=@gburd (last 2026-09-09T14:06). Awaiting maintainer merge.

No reply drafted or posted (nothing to reply to). No nudge (maintainer offline; do-not-nudge).

=======================================================================
## TASK 2 - Upstream-filed dependency issues/PRs (external projects)
=======================================================================

### FINDING: only lwext4 #100 outstanding; STILL no activity, none expected. Null result.

- **gkostka/lwext4 #100** (ext4_ext_check OOB read): OPEN, **0 comments**, created_at ==
  updated_at == **2026-07-14T14:24:21Z** (unchanged since filing, now across seven checks).
  gkostka/lwext4 last pushed 2024-03-22 (dormant) - no reply expected. Our fix ships in the
  osvunikernel/lwext4 fork OSv builds from, and is OSv PR #1449. Non-blocking. Leave open as the
  good-citizen report. No action available.
- **Full external author:gburd search:** the ONLY OSv-relevant EXTERNAL filing is lwext4 #100.
  (cloudius-systems/osv#1474 "OpenZFS: five filesystem tests fail under conf_zfs" is gburd's own
  issue in the OSv repo itself, not an external-dependency filing.) Everything else returned by the
  search (libdb, pgrust, turbovec, etc.) is unrelated projects.
- **openzfs/zfs / qemu / musl / acpica / firecracker:** 0 issues authored by gburd. No filings.

=======================================================================
## TASK 3 - External dependency currency (verified TODAY via git ls-remote / API)
=======================================================================

### OpenZFS (modules/open_zfs/openzfs submodule)
- upstream/master pin: gitlink **83020cf8** (= zfs-2.4.3), .gitmodules branch=zfs-2.4.3.
- newest stable release: **zfs-2.4.4** (tag peels to 71a9f957). Verified TODAY: no zfs-2.4.5,
  no zfs-2.5.x (zfs-2.4.99 is a dev tag, NOT a release).
- **OPEN PR #1488** (mergeable, non-draft, branch pr/openzfs-2.4.4): open_zfs gitlink =
  **71a9f957** = EXACTLY the dereferenced zfs-2.4.4 commit. Merge-tree CLEAN vs upstream/master.
  => master is exactly one point release behind; the correct newest-stable bump is already prepared
  and correctly pinned in #1488. Maintainer-gated. RISK: low (one point release; adaptation already
  written + merge-clean). DID NOT bump.

### lwext4 (modules/lwext4 build-time clone)
- master pins nothing: `git clone --depth 1 https://github.com/osvunikernel/lwext4.git` (floating).
- osvunikernel/lwext4 HEAD = **6f6d8f7c** (verified TODAY, unchanged).
- **OPEN PR #1500** (mergeable, head da1a54a2) pins the checkout to an exact commit whose gitlink
  target is 6f6d8f7c. Merging is a no-op on bits + removes the floating-clone reproducibility hazard.
  RISK: low. No bump needed. DID NOT touch.

### Other deps: unchanged, deliberate fork/tag pins (musl_1.2.1, musl_0.9.12, acpica, kbuild,
### swagger-ui, osv-gui). No currency action. (acpica is ~13y behind by design - a fact, not drift.)

### FINDING: OpenZFS one release behind (2.4.4 ready+clean in #1488); lwext4 pin ready+clean in
### #1500. Both maintainer-gated. Nothing else warrants a bump. DID NOT bump anything.

=======================================================================
## TASK 4 - Remaining plan (DONE / IN-PROGRESS / NOT-STARTED / BLOCKED)
=======================================================================

Synthesized from ROADMAP, BLOCKED-WINS-CURRENT, A2A-FINAL-VERDICT, QUEUED-FOLLOWUPS,
WAKEUP-LATENCY-FIX-BRIEF. Delta vs 2026-09-17b: the a2a capstone COMPLETED with a verdict; the
wakeup-latency residual is now being chased (adaptive-idle-spin, in progress).

### DONE
- **a2a CAPSTONE benchmark - COMPLETE (2026-09-17).** VERDICT: OSv SCALES (shape flipped
  declining->scaling); FASTER than Linux at VU8 (+17%, 1.17x) and VU16 (+29%, 1.29x); trails at
  VU32 median (-28%, 0.72x) SOLELY due to an intermittent OSv-specific cross-vCPU WAKEUP-LATENCY
  low-mode (proven via qemu-cpu discriminator; no Linux analog). Boxes terminated, 0 orphans.
  This is the M1 result, honestly framed. Full: .local/A2A-FINAL-VERDICT.md + .local/a2a-final/RESULT.md.
- M1 root-cause + writeup ("OSv declines" was substantially a run-order harness artifact + two
  teardown leaks, all now fixed). BANKED.
- 11 banked generic fixes, all open + merge-clean, none claimed as M1 parity: #1502 dentry AB-BA,
  #1503 per-chain dentry, #1504 TCB psABI, #1505 ZIL hires, #1506 ARC-max, #1507 fsync scan,
  #1508 physio per-iovec, #1509 per-queue completion, #1472 wake-pull. (#1501 idle-spin now
  un-drafted+ready; #1510 ext4 remains DRAFT.)
- Leak #1 (fd/gfdt EMFILE): root-caused + FIXED + 400-round-A/B-validated; review-ready
  (bank/fork-fd-reap-leak-reviewready). Blocked only on the fork-stack landing path.
- Leak #2 (fork-arena memory): REAL FIX COMPLETE + 5-gate-validated (400 rounds / 26,181 backends);
  banked (bank/fork-arena-real-reclaim). Supersedes the grow-mitigation. Same fork-stack dependency.
- P0.1 #1449 ext4 security rebase; P0.2 #1447->pr/ext4-perf-v2 functional part.
- #1478 native-ZFS runtime data pool: OPEN, non-draft, mergeable, merge-clean - carries 4a's exact
  zfsdev_init change PLUS the 4 pieces 4a lacks. 4a is RETIRED as a strict-subset (do NOT open it).

### IN-PROGRESS (do NOT touch - owned by other agents)
- **adaptive-idle-spin fix (agent racing lava expiry).** ROOT CAUSE localized in core/sched.cc:
  the wake path already suppresses the cross-vCPU IPI when the target is idle-POLLING, but the
  control is a FIXED spin count (#1501's blunt lever). FIX = ADAPTIVE per-CPU idle-spin window
  (guest-side, like Linux halt_poll_ns): grow when wakes are caught mid-spin, shrink toward a floor
  when genuinely idle - general scheduler improvement, fixes #1501's host-conditionality. Pushed to
  gh-fork bank/sched-adaptive-idle-spin (tip 4bedbfa6f). VALIDATION pending: isolate A/B +
  genuinely-idle no-regression gate + THE REAL TEST (re-run the a2a VU32 OSv cell; does the
  intermittent low-mode disappear) + p99. Brief: .local/WAKEUP-LATENCY-FIX-BRIEF.md.
- Leak #1 / Leak #2 landing: gated on the #1455/#1456 fork-stack composition (maintainer decision).

### BLOCKED (maintainer offline since 2026-08-03 - every merge blocks on that)
- Merge of master-eligible clean PRs: #1464 (APPROVED) + #1502/#1503/#1504 first; then #1488
  (OpenZFS 2.4.4) + #1500 (lwext4 pin); then #1478 (native data pool) + #1449 (security) + the ready
  standalone family (#1477/#1479-#1486/#1490-#1499/#1505-#1509/#1501/#1472 etc).
- Clear #1439 stale CHANGES_REQUESTED (everything answered through 2026-08-01).
- #1455/#1456 fork composition = the KEYSTONE. Gates the whole fork stack (#1445 NUMA-pools, #1475
  COW-nested, #1458 tracking, and BOTH banked leak fixes' landing path). The S1..S8 composition
  proposal is POSTED to #1458 (comment 5718101962), awaiting the maintainer's composition call.

### NOT STARTED (deferred per operator directive: chase the wakeup-latency residual FIRST)
- **M2 / PGXN** (every PGXN extension identical OSv-vs-Linux: pg_stat_statements, pgvector, PostGIS):
  DEFERRED until the wakeup-latency residual is chased. Same dlopen/ELF surface the fork/COW fixes
  repaired.
- **#1510 ext4 read-ahead**: DRAFT, waiting on an ext4 re-measure on current master.
- NUMA family rebase (#1438/#1441/#1445) onto master's SRAT/SLIT layer (when picking up NUMA).
- 4b RDSEED: fold into #1492 after #1492 review settles (do NOT open a competing PR).

=======================================================================
## TASK 5 - Draft-PR currency vs upstream (merge-tree from upstream/master)
=======================================================================

- upstream/master VERIFIED still **0e34e4dc2** (git fetch upstream = no movement). local master,
  gh-fork/master, origin/master ALL at 0e34e4dc2 (fork mirrors NOT behind).
- Because upstream is UNMOVED, this sweep introduces NO new conflicts.

Merge-tree --write-tree over all 56 open PR heads vs upstream/master (by exit code).
**48 CLEAN, 8 CONFLICTING - IDENTICAL set to the prior sweeps:**

- **#1440 inotify / #1449 ext4 heap-overflow** - TRIVIAL base-drift: conflict ONLY in
  modules/tests/Makefile (the `tests += ...so` line). A rebase re-appends the test line. Not substantive.
- **#1438 / #1441 / #1445 NUMA family** - SUBSTANTIVE: add/add conflict in core/numa.cc +
  include/osv/numa.hh (+ modules/tests/Makefile; + tests/tst-numa.cc for #1441). master gained a
  SRAT/SLIT layer (a92c44f9b) after these branched. Needs a real rebase onto the new NUMA layer.
  #1445 is also fork-stack-adjacent.
- **#1456 / #1475 fork COW stack** - libc/signal.cc + modules/tests/Makefile. Fork-stack dependent
  (blocked on #1455/#1456 composition). DO NOT TOUCH.
- **#1458 tracking PR** - many files (.gitignore, .gitmodules, Makefile, apps submodule,
  virtio-balloon.cc, exported_symbols, ...). Expected for the DO-NOT-MERGE tracking unit. DO NOT TOUCH.

### FINDING: upstream unmoved -> NO new conflicts. Conflicts unchanged (#1440/#1449 trivial;
### #1438/#1441/#1445 substantive NUMA rebase; #1456/#1475/#1458 fork-stack/tracking, owned/blocked).
### DID NOT rebase/force-push. Temp refs/prheads/* fetched for the scan were all deleted after use.
### **#1501 is CLEAN** on master (Task 7 mergeable-clean verification).

=======================================================================
## TASK 6 - Sync local osv + osv-apps
=======================================================================

### osv (~/ws/osv)
- `git fetch upstream --prune` done (read-only). upstream/master 0e34e4dc2 UNMOVED.
- local master, gh-fork/master, origin/master ALL at 0e34e4dc2 - fork mirrors NOT behind.
- Working branch = wip/pg-rx-directwake (report only; not merged/rebased; carries the LIVE
  wakeup-latency work). Recorded apps gitlink on this branch = 57c60798 (the branch's own pin).

### osv-apps (checkout at ~/ws/osv/apps)
- `git fetch --all --prune` done (origin/codeberg/gh-upstream/gh-fork/cloudius).
- checkout HEAD = **3f93f43** on branch pr/phony-build-and-io-method-comment (unchanged).
- cloudius/master = **b2d53b34** (unmoved).
- divergence 3f93f43 vs cloudius/master: **2-ahead / 655-behind** (unchanged). Both ahead commits
  touch only postgres18-musl (seed_copy fix + shadowed-build-target/io_method note) -> clean future rebase.
- **osv-apps #73 (postgres18-musl demo): CURRENT.** OPEN, DRAFT (held on OSv fork/COW landing),
  headRefOid = 3f93f43 = EXACTLY our checkout pin. Verified.

### FINDING: everything current. Master + fork mirrors at 0e34e4dc2; apps checkout at #73's exact
### pin; clean future rebase. Fetch + report only, no merge/rebase.

=======================================================================
## TASK 7 - Open PRs for finished + unblocked features
=======================================================================

### FINDING: NO PR opened. #1501 verified ready (no action needed). adaptive-idle-spin NOT openable
### by me (fork-stacked as banked + other-agent-owned + needs its validation).

- **#1501 (OSV_IDLE_SPIN): VERIFIED READY.** draft=false, reviewDecision=(none, awaiting first
  review), mergeable=MERGEABLE, branch pr/sched-idle-spin-v2 @ 296b9ec6, merge-tree CLEAN on
  upstream/master. Nothing more to do - it awaits maintainer review like any master PR. LEFT AS-IS.
- **adaptive-idle-spin (bank/sched-adaptive-idle-spin, tip 4bedbfa6f):** the adaptive commit itself
  touches core/sched.cc + include/osv/sched.hh + apps - the CODE is master-facing (the idle path
  exists on master, is NOT fork-blocked). BUT the branch as banked is STACKED on the fork-arena leak
  fixes (43fcdca79 + c2e86203a) and a ZIL probe stack, so it does NOT merge-clean to master as-is
  (merge-tree = CONFLICT, expected). It would need commit 4bedbfa6f isolated (cherry-picked) onto
  master before it could open as a standalone PR. Per brief: the other agent owns it AND it needs its
  own validation (the a2a VU32 re-run showing the low-mode disappears). NOTE it will be openable once
  isolated + validated, but I did NOT open it and did NOT touch the branch.
- gh-fork bank/* are otherwise ALL the leak work (bank/fork-arena-*, bank/fork-fd-reap-leak*) -
  fork-stack-dependent, blocked on #1455/#1456, brief-named off-limits. Cannot open (rule).
- 4a native-ZFS: SUPERSEDED by open #1478 (strict subset + non-functional alone). Do NOT open.
- 4b RDSEED: fold into #1492 after review settles - do NOT open a competing PR.
- NUMA family rebase (#1438/#1441/#1445): substantive SRAT/SLIT rebase, not a new PR.
- Everything else DONE + validated is ALREADY open (the banked fixes, #1478, #1488, #1500, #1459, etc).

### Did NOT open/validate anything: no standalone+clean+validated+not-owned candidate exists.

=======================================================================
## TASK 8 - Local + LAN tidiness
=======================================================================

### Worktrees (osv)
`git worktree list` = 12 (main + 11 linked). ALL directories PRESENT on disk; `git worktree prune
--dry-run` = no-op (0 prunable). No change vs prior sweep except:
- /scratch/gburd/osv-adaptive [bank/sched-adaptive-idle-spin @ 4bedbfa6f] = the LIVE
  adaptive-idle-spin worktree. OFF-LIMITS. NOT touched.
- .local/worktrees/fork-arena [integ/pg-fork-arena @ 858dd78f2] = the LEAK work. NOT touched.
- /tmp/rxpool-wt [rxpool-fix @ 859210d54] = a live linked worktree; LEFT.
All 11 linked worktrees load-bearing (open PR / active branch lines). 0 pruned, 0 prunable.

### /tmp scratch
df: / and /tmp = 3.7T, **40% used, 2.1T free**. NO space pressure.
- Multiple LIVE agents are actively writing here RIGHT NOW: base_sched.cc (07:xx today) = the
  sched/wakelat work; aio_leakrun.sh (Sep 16) = the leak agent. OFF-LIMITS.
- Old (>7d) OSv helper scripts exist (osv_boot.sh, osvrun.sh, osv_zpool.sh, osv_disk.sh,
  osv_prep.sh, osv_image.sh, ssh_osv.sh, osv-wakepull-results) - all tiny (<2KB), reclaim nothing,
  and given live sched/wakelat/leak agents are running I am NOT sure they are dead. With zero space
  pressure the correct call is LEAVE them. (opstats/ssi/gi/fa/wtail/gc-wt/recno/mvcc/getnext + libdb/
  solnix files are NOT ours; not touched.)
- **DELETED NOTHING from /tmp** (nothing OSv-sweep-CERTAIN-dead; live agents active; no pressure).
- This sweep created NO /tmp scratch (all git/gh/aws read-only).

### EC2 (AWS_PROFILE=lava, account 769093516156) - REPORT-ONLY (account expiring)
- Launched ZERO, terminated ZERO. Owner=agent-maintsweep* instances = 0 (nothing of mine).
- **0 available (unattached) volumes** across us-east-2 / us-east-1 / us-west-2. No orphans.
- Running instances (NONE mine, NONE touched - report only):
    - **i-016e19e060a57409f osv-wakelat (agent-wakelat, m5d.metal, launched 2026-09-18T10:39)** =
      the LIVE wakeup-latency box, NAMED off-limits. LEFT UNTOUCHED (no ssh, no terminate).
    - i-0d6b651569c3d9142 libdb-q7 (c7i.12xlarge) = libdb project, not OSv, not mine. LEFT.
- ORPHAN CHECK on the dying lava account: 0 orphan instances of mine, 0 orphan volumes. The only
  OSv box (i-016e...) is the owned live box. When lava dies, any un-terminated box just vanishes with
  the account - nothing of MINE to clean, and I am forbidden to touch the one owned box.
- LAN hosts touched: NONE.

### FINDING: worktrees all present + load-bearing (0 pruned/prunable); no OSv-sweep-CERTAIN-dead
### scratch to remove; no space pressure; 0 EC2 of mine + 0 orphans + 0 available volumes on lava.
### The one OSv box running is the owned live wakelat box - left untouched per brief.

=======================================================================
## CHANGES MADE THIS SWEEP (safe + clearly-correct only)
=======================================================================
1. git fetch upstream --prune (osv) + git fetch --all --prune (osv-apps) - read-only sync.
2. Fetched open PR heads into refs/prheads/* for merge-tree checks, then DELETED all of them
   (0 remaining). No persistent local refs created.
3. Wrote this report.

NOT done (by rule / needs operator judgment):
- No reviewer reply posted (0 unanswered comments; no reply to the #1458 proposal or #1501).
- No PR opened (#1501 already ready; adaptive-idle-spin fork-stacked + other-agent-owned + unvalidated).
- No rebase / force-push (conflicts reported only).
- No merge (all maintainer-gated).
- No /tmp deletion (nothing sweep-CERTAIN-dead; live agents active; no pressure), 0 worktrees pruned.
- No EC2 launch/terminate on lava (account expiring; report-only). Did not touch i-016e19e060a57409f.
- Did NOT bump any dependency.
- Did NOT touch the in-flight leak/wakelat work or the working tree.

=======================================================================
## ITEMS NEEDING YOUR JUDGMENT (flagged)
=======================================================================
A. **#1439:** clear the stale CHANGES_REQUESTED (everything answered through 2026-08-01) - maintainer only.
B. **Merge the clean, ready, maintainer-gated PRs when back:** #1464 (APPROVED) + #1502/#1503/#1504
   first; then #1488 (OpenZFS 2.4.4) + #1500 (lwext4 pin); then #1478 (native pool) + #1449 (security)
   + the ready standalone family (incl. #1501 idle-spin, #1472 wake-pull).
C. **#1455/#1456 fork composition** = the keystone. The S1..S8 proposal is POSTED to #1458 (comment
   5718101962, no reply/reaction) - awaiting your/the maintainer's composition call. Unblocks BOTH
   banked leak fixes.
D. **adaptive-idle-spin:** once the other agent isolates commit 4bedbfa6f onto master AND its a2a-VU32
   validation lands (low-mode gone, default-safe), it becomes openable as a standalone master PR. The
   other agent owns it + it needs that validation - I did NOT open it. Your/their call on timing.
E. **#1438/#1441/#1445 NUMA family:** need a real rebase onto master's SRAT/SLIT layer (a92c44f9b) -
   substantive. Do when picking up the NUMA thread.
F. **4b RDSEED:** fold into #1492 (do NOT open a competing PR) after #1492 review.
G. **M2/PGXN + #1510 ext4 re-measure:** DEFERRED per operator directive (chase the wakeup-latency
   residual first, which is exactly the adaptive-idle-spin work now in progress).

=======================================================================
## PROGRAM STATE
=======================================================================
Clean holding, one active thread. The a2a capstone is DONE (OSv scales; +17%/+29% at VU8/16,
-28% VU32 median on the named cross-vCPU wakeup-latency residual). The ONE actionable thread is the
adaptive-idle-spin fix chasing that residual (in progress, other-agent-owned, racing lava expiry).
Everything else is either done+open (maintainer-gated merges), banked+fork-stack-blocked (both leaks,
gated on the #1458 composition call), or deferred (M2/PGXN, #1510 ext4 re-measure). Zero new reviewer
comments, zero maintainer reply to the composition proposal, upstream unmoved, deps stable, 0 EC2
orphans of mine on the dying lava account. Nothing new to open; nothing safe left to change.
