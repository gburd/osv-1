# OSv upstreaming maintenance/tidy sweep - 2026-09-16

READ-heavy sweep. Did NOT touch the in-flight leak work (bench/leakhunt,
bank/fork-fd-reap-leak, integ/pg-fork-arena worktree, core/fork_arena.cc, PR #1458).
Another worker owns those.

Environment: no AWS credentials available in this shell (EC2 inventory not reachable
from here - see Task 8). SSH agent: /run/user/1000/wezterm/agent.3913155.

=======================================================================
## TASK 1 - PR reviewer comments/issues
=======================================================================

Scanned all 56 open PRs authored by gburd (both the issue-comments API and the
pulls review/inline-comments API, filtering out bots and gburd himself).

Only 5 PRs have any non-bot, non-author (human reviewer) activity:
  #1439, #1455, #1461, #1463, #1464.

For every one of the 5, the LAST event in the thread (issue comment, inline
comment, and review) is gburd's - the reviewer's last comment always has a later
gburd reply. GraphQL review-thread check confirms: every review thread across all
5 PRs has lastBy=gburd. #1439 and #1455 threads are all resolved=true. #1461/#1464
threads are unresolved but the reviewer has not returned (last comment is gburd's).

Newest reviewer (nyh / wkozaczuk) activity anywhere:
  #1439 2026-07-15, #1461 2026-08-03, #1463 2026-08-01, #1455 2026-08-03,
  #1464 2026-08-03. NO new reviewer activity since the last sweep (09-14).
The only post-09-15 PR updates (#1509 09-15, #1458 09-16) are gburd's own.

### FINDING: 0 unanswered substantive reviewer comments. No reply drafted.

### Two specifically-flagged PRs, verified:
- **#1439 signalfd (CHANGES_REQUESTED, believed stale): CONFIRMED STALE.**
  nyh's review (2026-07-15) raised 2 points (extern "C"; return-true-vs-delivered
  behavior) plus Copilot's findings. ALL addressed in the current head: extern "C"
  removed (plain C++ decl in signal.hh); single-consumer delivery (returns after
  first matching signalfd); SIGKILL/SIGSTOP FILTERED via sigdelset (not EINVAL -
  gburd self-corrected his own earlier misstatement on 2026-09-08, matching Linux
  do_signalfd4). All 8 review threads resolved. The CHANGES_REQUESTED flag was
  never cleared by nyh, but there is nothing substantive left. Maintainer-gated
  (clear the flag / merge). No nudge posted (maintainer offline).
- **#1464 load-balancer disperse (APPROVED, awaiting merge): CONFIRMED.**
  nyh APPROVED 2026-08-03. His last inline question (the cpus.size()*8 cap) was
  answered in-thread by gburd on 2026-09-09. Nothing outstanding. Awaiting
  maintainer merge.

=======================================================================
## TASK 2 - Upstream dependency PRs/issues WE filed (external projects)
=======================================================================

Exactly ONE issue was ever filed by us against a true external dependency:

- **gkostka/lwext4 #100** - "Out-of-bounds read: ext4_ext_check() does not bound
  eh_max/eh_entries to block capacity". Author gburd, filed 2026-07-14.
  STATUS: **OPEN, 0 comments, updated_at STILL 2026-07-14T14:24:21Z** - unchanged
  since filing, no maintainer reply. The upstream (gkostka/lwext4) is dormant
  (last push 2024-03-22), so no reply is expected. Non-blocking: our fix ships in
  the osvunikernel/lwext4 fork OSv actually builds from, and is also OSv PR #1449.
  ACTION: none available. Leave open as the good-citizen upstream report.

- **openzfs/zfs**: `gh search issues/prs --author gburd --repo openzfs/zfs` = NONE.
  The OpenZFS-on-OSv fixes are OSv-platform-layer patches in
  modules/open_zfs/patches/, not upstream OpenZFS bugs. Nothing filed, nothing to
  file. Confirmed this sweep.

- osv-apps #71/#72/#73 are against OUR OWN osv-apps fork (covered in Task 6), not
  external deps.

### FINDING: only lwext4 #100 outstanding; no new activity, none expected. Null.

=======================================================================
## TASK 3 - External dependency currency
=======================================================================

Submodules on master (.gitmodules): acpica, apps, swagger-ui, osv-gui,
musl_0.9.12, musl_1.2.1, kbuild, open_zfs. Plus the lwext4 build-time clone.

### OpenZFS (modules/open_zfs/openzfs submodule)
- master pin: branch **zfs-2.4.3**, gitlink 83020cf8 (release 2026-06-12).
  (The working-tree .gitmodules on this wip branch shows a STALE zfs-2.4.2 /
  6330a45b0 - local, not master; ignore it.)
- newest upstream release: **zfs-2.4.4 (2026-08-21)**. (Also out: 2.3.9, 2.2.11.)
- **OPEN PR #1488** bumps master to 2.4.4 (branch zfs-2.4.4, gitlink 71a9f957 =
  EXACTLY the zfs-2.4.4 tag commit). #1488 is not-draft, MERGEABLE, merge-tree
  CLEAN vs upstream/master. So the newest appropriate release is already prepared
  and correctly pinned; master is one point release behind pending that merge.
- CORRECTION: the prior PROGRAM-STATE note "OpenZFS 2.4.4" (as if master were on
  it) was wrong - master is 2.4.3; 2.4.4 is the pending #1488. Corrected in
  .local/PROGRAM-STATE-2026-09-16.md this sweep.
- RISK of the bump: #1488 already carries the platform-layer adaptations for 2.4.4
  (per its file list + deps-currency.md); the OSv patch series applies to it. Low
  risk, but it is a maintainer merge, not something to force here.

### lwext4 (modules/lwext4/Makefile build-time clone)
- master: floating `git clone --depth 1 https://github.com/osvunikernel/lwext4.git`
  with NO pinned commit (a reproducibility hazard - two builds can link different
  revisions).
- **OPEN PR #1500** pins it to commit **6f6d8f7c**, which is the CURRENT tip of
  osvunikernel/lwext4 master (2025-07-04, "Disable journaling and link with
  -nodefaultlibs"). Merge-tree CLEAN. Merging #1500 is a no-op on bits and removes
  the hazard. Newest-appropriate pin. No bump needed.

### Other deps (verified, no action)
- musl_1.2.1 -> osvunikernel/musl @ 1.2.1; a 1.2.x fork rebase is a standing
  backlog project (deps-currency.md), not a sweep task, not blocking anything.
- acpica / swagger-ui / osv-gui / kbuild / musl_0.9.12: cloudius/osvunikernel
  forks, no outstanding currency issue flagged in any doc.

### FINDING: OpenZFS one release behind (2.4.4 ready in #1488), lwext4 unpinned
### (pin ready in #1500). Both fixes are OPEN, merge-clean, maintainer-gated.
### DID NOT bump anything.

=======================================================================
## TASK 4 - What remains on the plan (DONE / IN-PROGRESS / NOT-STARTED / BLOCKED)
=======================================================================

Synthesized from ROADMAP.md, NORTH-STAR-PLAN.md, PROGRAM-STATE-2026-09-16.md,
M1-REFRAME-LANDMARK.md, DECLINE-ROOT-CAUSE-FOUND.md.

### DONE
- M1 root-cause + writeup: the "OSv declines VU8->VU16->VU32" headline was
  substantially a RUN-ORDER HARNESS ARTIFACT (never-rebooting harness + an agent
  that voided the clean fresh-boot cell). Fresh-boot VU32 = 215k, healthy. The
  real, more valuable finding is a within-boot fork/teardown wedge (Task: leaks).
  M1 deliverable = the characterization; BANKED (M1-FIX-LEDGER.md, reframe doc).
- 11 banked generic fixes, all FILED open+clean, none claimed as M1 parity:
  #1502 dentry AB-BA, #1503 per-chain dentry, #1504 TCB psABI, #1505 ZIL hires,
  #1506 ARC-max, #1507 fsync scan, #1508 physio per-iovec, #1509 per-queue
  completion, #1472 wake-pull. (#1501 idle-spin, #1510 ext4 remain draft.)
- Leak #1 (fd/gfdt) fully root-caused + FIXED + A/B-validated (400 rounds, gfdt
  flat vs climbs-to-65535 EMFILE@224). Banked on bank/fork-fd-reap-leak. [Owned
  by the leak worker - not touched this sweep.]
- Reviewer hygiene: all human review points on all PRs addressed (Task 1).
- P0.1 #1449 ext4 security rebase; P0.2 #1447->pr/ext4-perf-v2 (functional part).

### IN-PROGRESS (do NOT touch - other worker)
- Leak #2 (per-fork memory leak): root-caused (fork-arena g_bump never returns
  carved VA -> identity-heap fallback that destroy_address_space never frees,
  ~0.74-1.8 MB/backend, OOM ~round 280). Fix iterating: v1 VA-reclaim and
  v2/v3 per-object-tracker both crashed/wedged; the proven-correct design is an
  AS-tied identity-heap tracker with a non-global hot-path lock. Agent 9bec3830.
  Load-bearing invariant established (only VA coherent in every AS is safe to
  free cross-AS = the identity heap). NOT done.
- OSV_IDLE_SPIN HammerDB verdict: SECONDARY now (the reframe showed run-order
  swamped it). Isolate win (+56-140%) stands; end-to-end transfer un-drafts #1501
  if it holds. Superseded in priority by the leak work.

### BLOCKED (maintainer offline; every merge is blocked on that)
- Merge order of the master-eligible clean PRs: #1502/#1503/#1504 + #1464
  (APPROVED). All merge-clean, non-fork-gated. BLOCKED on maintainer.
- Clear #1439's stale CHANGES_REQUESTED flag. BLOCKED on maintainer.
- #1488 (OpenZFS 2.4.4) + #1500 (lwext4 pin): clean, BLOCKED on maintainer.
- #1455/#1456 fork composition (add/add, not an increment) - a maintainer DESIGN
  decision on how they compose. Blocks the fork stack (#1445 NUMA-pools,
  #1475 COW-nested, #1458 tracking, and the two leak fixes' landing path).
- P1 p99/latency: no valid p99 base on either ISA (the reframe voids the old
  contaminated curve; needs a clean fresh-boot-per-cell OSv-vs-Linux base).
- Firecracker-on-current-base: NOT REACHED in campaign 3 (budget), and the AWS
  substrate is quota-gated (5 vCPU, 200-vCPU request open on the `lava` account;
  no metal can launch yet). Blocked on quota + a fresh clean base.

### NOT STARTED
- **M2 / PGXN** (every PostgreSQL extension works OSv == Linux): NOT STARTED. The
  next major phase once M1/leaks conclude. Same dlopen/ELF surface as before.
- ext4 #1510 re-measurement: the read-ahead PR is DRAFT pending a re-measure on a
  valid base; the perf numbers are NOT re-validated (functional part done).
- NixOS bench-host flake: the ROADMAP directive is NixOS>Debian>Fedora for the
  bench HOST, but the pinned bench-host flake is "build it" = NOT built yet
  (Debian 12 AMI is the current default host).

### NOTE on honesty
M1 parity is NOT demonstrated; it is characterized to a root (wakeup latency +
the two fork/teardown leaks). The banked fixes stand on their own merit. M2 is
the next phase regardless of whether M1 formally "closes."

=======================================================================
## TASK 5 - Draft PR currency vs upstream
=======================================================================

- upstream/master VERIFIED still at **0e34e4dc2** (unmoved since 2026-08-17;
  git fetch upstream confirms). gh-fork/master, origin/master, local master all
  at 0e34e4dc2 too.
- Because upstream is UNMOVED, this sweep introduced NO new conflicts. The
  merge-tree conflicts below are PRE-EXISTING base-drift (PRs that branched before
  earlier upstream commits) or intra-family cross-conflicts, not new drift.

Merge-tree (--write-tree --messages) of every open PR head vs upstream/master
(0e34e4dc2). 48 of 56 CLEAN. The 8 CONFLICTING:

- **#1440 inotify** - conflict ONLY in modules/tests/Makefile. TRIVIAL base-drift:
  branched from 07f61154a; master since got close_range/libaio/setrlimit/SRAT/zfs
  commits that touched tests/Makefile, so the `tests += tst-inotify.so` line
  collides. A rebase resolves it (re-append the test line). Not substantive.
- **#1449 ext4 heap-overflow** - same, modules/tests/Makefile base-drift only.
- **#1438 / #1441 / #1445 NUMA family** - conflict in core/numa.cc + numa.hh
  (add/add) + tests/Makefile. SUBSTANTIVE: master got `a92c44f9b numa: discover
  topology from SRAT/SLIT` after these branched, so their numa.cc/numa.hh now
  collide with the upstream NUMA code. Needs a real rebase onto the new upstream
  NUMA layer, not a trivial re-append. #1445 is also fork-stack-adjacent (stacked
  on #1441).
- **#1456 / #1475 fork COW stack** - libc/signal.cc + tests/Makefile. Fork-stack
  dependent (blocked on the #1455/#1456 composition decision). DO NOT TOUCH.
- **#1458 tracking PR** - .gitignore/.gitmodules/Makefile/apps. Expected for the
  DO-NOT-MERGE tracking unit. Another worker owns it. DO NOT TOUCH.

### FINDING: upstream unmoved -> no NEW conflicts. Conflicts are pre-existing
### base-drift (#1440/#1449 trivial; #1438/#1441/#1445 substantive NUMA rebase) or
### fork-stack/tracking (#1456/#1475/#1458, owned/blocked). DID NOT rebase/force-push.

=======================================================================
## TASK 6 - Sync local osv + osv-apps with upstream
=======================================================================

### osv (~/ws/osv)
- `git fetch --all --prune` done (origin/upstream/gh-fork).
- upstream/master 0e34e4dc2 UNMOVED. local master, gh-fork/master, origin/master
  ALL at 0e34e4dc2 - fork mirrors are NOT behind. (Working branch is
  wip/pg-rx-directwake; not merged/rebased - report only.)

### osv-apps (checkout at ~/ws/osv/apps, the `apps` submodule)
- `git fetch --all --prune` done (origin/codeberg/gh-upstream/gh-fork/cloudius).
- current checkout HEAD = **3f93f43** ("postgres18-musl: seed_copy must not
  inherit rofs modes") on branch pr/phony-build-and-io-method-comment.
- cloudius/master = b2d53b34 (2026-08-02). The OSv master `apps` gitlink is
  b2d53b348 = EXACTLY cloudius/master, so the master submodule pointer is current.
- our fork mirrors (gh-fork/master, codeberg/master) = 0b98404 (fork line, expected
  to differ - that is osv-improvements-style fork work, not master).
- divergence of our 3f93f43 checkout vs cloudius/master: 655-behind / 2-ahead.
  BUT none of the 655 cloudius commits touch postgres18-musl -> a future rebase is
  clean and the seed_copy fix stays intact.
- **osv-apps #73 (seed_copy fix, pin 3f93f43): CURRENT.** #73 is OPEN, DRAFT
  (held on OSv fork/COW landing), headRefOid = 3f93f43 = EXACTLY our checkout pin.
  Verified current. (#71 ec2-audit idle; #72 io-uring-bench closed.)

### FINDING: everything current. Master + fork mirrors at 0e34e4dc2; apps gitlink
### current; osv-apps #73 pin matches; clean future rebase. DID NOT merge/rebase
### working branches.

=======================================================================
## TASK 7 - Validate + open PRs for finished-but-unblocked features
=======================================================================

Searched for DONE + validated + blocker-cleared candidates. Excluded (by rule)
anything fork-stack-dependent (#1455/#1456-gated) and the leaks.

Candidate found: gh-fork branch **wip/native-zfs-fixes** (2 commits, G-signed,
merge-tree CLEAN vs upstream/master, no open PR):
  - 4a `59f4f12ad` loader: init ZFS control device when preloading libsolaris
  - 4b `1600b68cb` random: RDSEED + boot-seed when no HW RNG

### DID NOT open a PR. Reasons (Task-7 bar = standalone AND clean AND validated):
- 4b OVERLAPS already-open #1492 (random early /dev/random from RDRAND) and #1493
  (aarch64 RNDR) - all three touch drivers/random.cc in the same region. 4b is a
  superset adding RDSEED (21 refs vs 0 in #1492). Opening it fresh would collide
  with / duplicate #1492/#1493. Recommendation: fold RDSEED into #1492, not a new PR.
- 4a IS standalone + merge-clean, BUT NOT VALIDATED end to end: ROADMAP ITEM 4
  states "Metal validates the real native boot" - the fs=ramfs -> /dev/zfs ->
  zpool create path has not been run green on hardware (only the 4b RNG bit-logic
  had a host self-check). Fails the "validated" requirement.

DRAFTED + FLAGGED: .local/maint-2026-09-16/native-zfs-fixes-DRAFT-FLAGGED.md
(4a PR body ready to open after a metal validation; 4b reconciliation note).

### FINDING: no PR opened - nothing meets standalone+clean+validated. #1459/#1478/
### #1488 (the other unblocked ZFS PRs) are already open, clean, non-draft.

=======================================================================
## TASK 8 - Local + LAN tidiness
=======================================================================

### Worktrees (osv)
`git worktree list` = 11 (main + 10 linked). All directories EXIST; nothing
prunable (`git worktree prune` would be a no-op - not run). Notable:
- .local/worktrees/fork-arena [integ/pg-fork-arena] = the LEAK work. NOT touched.
- /tmp/rxpool-wt [rxpool-fix] = a LIVE git worktree, 40-ahead of gh-fork/wip/pg-
  rx-pool, has uncommitted deletions. NOT dead scratch - it is a linked worktree
  carrying branch state. LEFT AS-IS (deleting would strand the branch checkout).
All 10 linked worktrees appear load-bearing (match open PR / active branch lines).

### /tmp scratch
df: / and /tmp = 3.7T, 41% used, 2.1T free. NO space pressure.
Large /tmp dirs are OTHER projects, NOT this OSv sweep:
  74G x3 solnix-* (aria2 build), 27G noxu-xbench, 5.5G xtc_local_pgdata (XTC),
  5.7G lut-xbench-runs, etc. NOT mine - did NOT delete.
This sweep created NO /tmp scratch. Nothing OSv-sweep-dead to reclaim.

### EC2 / LAN
- NO AWS credentials in this shell (`aws` returns NoCredentials for us-east-1/2,
  us-west-2). Cannot enumerate EC2 from here. I did NOT spin any box this sweep
  (READ-heavy tidy), so I created 0 boxes and there are 0 boxes of mine to
  terminate. The leak worker's box (agent 9bec3830) is owned by that worker and
  would not be touched regardless; I cannot see it from here anyway.
- LAN hosts touched: NONE (as expected).

### FINDING: worktrees all present + load-bearing (0 pruned, 0 prunable); no OSv
### scratch to clean; no space pressure; no EC2 access from here + 0 boxes created
### by me; 0 LAN hosts touched.

=======================================================================
## CHANGES MADE THIS SWEEP (safe + clearly-correct only)
=======================================================================
1. git fetch --all --prune on osv and osv-apps (read-only sync).
2. Fetched all 56 open PR heads for merge-tree checks (refs/prheads/*, local only).
3. Corrected the stale "OpenZFS 2.4.4" claim in
   .local/PROGRAM-STATE-2026-09-16.md -> master is 2.4.3; 2.4.4 is the pending
   #1488. (Our own doc; factual correction.)
4. Wrote this report + .local/maint-2026-09-16/native-zfs-fixes-DRAFT-FLAGGED.md.

NOT done (by rule / needs your judgment):
- No reviewer reply posted (0 unanswered comments to reply to).
- No PR opened (Task 7 bar not met; 4a drafted+flagged).
- No rebase / force-push (conflicts reported only).
- No merge (all maintainer-gated).
- No /tmp deletion (nothing OSv-sweep-dead), no worktree pruned (none prunable).
- Did NOT touch the leak work (#1458, bank/fork-fd-reap-leak, integ/pg-fork-arena,
  core/fork_arena.cc).

=======================================================================
## ITEMS NEEDING YOUR JUDGMENT (flagged)
=======================================================================
A. #1439: clear the stale CHANGES_REQUESTED flag (everything answered) - maintainer.
B. Merge the clean, ready, maintainer-gated PRs when back:
   #1502/#1503/#1504, #1464 (APPROVED), #1488 (OpenZFS 2.4.4), #1500 (lwext4 pin).
C. native-zfs-fixes 4a: open standalone AFTER a metal fs=ramfs->zpool validation
   (draft body ready). 4b: reconcile RDSEED into #1492/#1493 rather than a new PR.
D. #1438/#1441/#1445 NUMA family need a real rebase onto master's new SRAT/SLIT
   NUMA layer (a92c44f9b) - substantive, not trivial base-drift.
