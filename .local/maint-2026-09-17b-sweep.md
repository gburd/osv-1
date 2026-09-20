# OSv upstreaming maintenance/tidy sweep - 2026-09-17b

Same-day follow-on to the 2026-09-17 (morning) sweep (.local/maint-2026-09-17-sweep.md).
READ-heavy. Built on the prior sweep; re-verified everything rather than re-reporting blind.

DID NOT TOUCH (in-flight, owned by other agents, per brief):
- LIVE a2a benchmark boxes i-005c5bfb32d8f12aa (a2afinal-metal, m5d.metal) +
  i-0aee60adbbece9746 (a2afinal-drv, c5.4xlarge), Owner=agent-a2afinal. No ssh, no terminate.
- Branches/files: bench/leakhunt, bank/fork-fd-reap-leak*, bank/fork-arena-real-reclaim,
  bank/fork-arena-grow-mitigation, core/fork_arena.cc, PR #1458, .local/leak2/*, .local/a2a-final/*,
  the fork-arena + a2afinal-base worktrees.

Environment: SSH agent /run/user/1000/wezterm/agent.3913155. AWS lava profile WORKS
(account 769093516156, us-east-2).

## HEADLINE DELTA vs the morning 2026-09-17 sweep: EFFECTIVELY ZERO material change.
- upstream/master STILL 0e34e4dc2 (unmoved) -> no new conflicts.
- 0 new reviewer comments anywhere; newest human reviewer touch is still 2026-08-03.
- The one #1458 update since the morning sweep is gburd's OWN composition-proposal comment
  (id 5718101962, posted 2026-09-17T16:51:49Z) - NOT a reply to it. No maintainer reply exists.
- Deps unchanged: OpenZFS one point release behind (2.4.4 ready+clean in #1488), lwext4 pin
  ready+clean in #1500, lwext4 #100 still 0 comments/unchanged.
- osv-apps #73 pin still current (3f93f43 = checkout).
- a2a capstone benchmark still RUNNING (setup phase; no verdict file yet).
- 0 EC2 of mine + 0 orphan volumes across us-east-{1,2}/us-west-2.

=======================================================================
## TASK 1 - PR reviewer comments/issues
=======================================================================

Scanned ALL 56 open gburd PRs three ways (issue-comments API, pulls inline-comments API,
pulls reviews API), filtering bots (Copilot/[bot]) and gburd himself.

### FINDING: 0 new reviewer activity. Nothing to reply to or post.

Newest NON-gburd, NON-bot human activity anywhere is unchanged:
- issue-comments: newest = @nyh #1455 2026-08-03T12:38 (before that @wkozaczuk #1463 08-01,
  @nyh #1439 07-15). Nothing after.
- inline review comments: newest = @wkozaczuk #1455 2026-08-03T14:01 (and the #1461 nyh
  thread same day). Nothing after.
- reviews: newest = @nyh APPROVED #1464 2026-08-03T14:29. Nothing after.

Every post-morning-sweep PR touch is gburd's own or the leak/a2a agents'.

### #1458 proposal-comment reply check (explicit brief ask):
The comment I posted 2026-09-17 (the S1..S8 fork-generation composition proposal, id
5718101962, created 2026-09-17T16:51:49Z, author=@gburd) has **NO reply**. #1458's four
issue-comments are ALL gburd's (2026-08-15, 08-28, 09-11, 09-17). No maintainer has replied.
(Note: the morning sweep quoted "T12:00" for the #1458 touch; the actual proposal-comment
timestamp is 16:51:49Z. Same conclusion either way: it is gburd's own post, not a reply.)

### Two flagged PRs, re-verified TODAY:
- **#1439 signalfd (CHANGES_REQUESTED): CONFIRMED STILL STALE.** reviewDecision=CHANGES_REQUESTED,
  mergeable=MERGEABLE, non-draft. All 8 review threads resolved=true, every one lastBy=@gburd
  (last 2026-08-01T17:09). nyh's flag never cleared; nothing substantive outstanding. Maintainer-gated.
- **#1464 load-balancer disperse (APPROVED): CONFIRMED.** reviewDecision=APPROVED,
  mergeable=MERGEABLE, non-draft. 6 review threads unresolved but each lastBy=@gburd
  (last 2026-09-09T14:06). Awaiting maintainer merge.

No reply drafted or posted (nothing to reply to). No nudge (maintainer offline; do-not-nudge).

=======================================================================
## TASK 2 - Upstream-filed dependency issues/PRs (external projects)
=======================================================================

### FINDING: only lwext4 #100 outstanding; STILL no activity, none expected. Null.

- **gkostka/lwext4 #100** (ext4_ext_check OOB read): OPEN, **0 comments**, created_at ==
  updated_at == **2026-07-14T14:24:21Z** (unchanged since filing; now across six checks).
  gkostka upstream last pushed 2024-03-22 (dormant) - no reply expected. Our fix ships in the
  osvunikernel/lwext4 fork OSv builds from + is OSv PR #1449. Non-blocking. Leave open as the
  good-citizen report. No action available.
- **Full external author:gburd search:** the ONLY OSv-relevant external filing is lwext4 #100.
  Everything else returned (berkeleydb/libdb #148/#149/#159/#165, malisper/pgrust #39,
  RyanCodrai/turbovec #70, crynta/terax-ai, postgresml/pgcat, dagster, vector, mentat, Symas,
  flake-templates) is OTHER projects, not OSv, not this program.
- **openzfs/zfs**: 0 issues authored by gburd (the ~40 openzfs URLs in .local are cited prior
  art, not our filings). Nothing filed at qemu/musl/acpica/firecracker.

=======================================================================
## TASK 3 - External dependency currency (verified TODAY via git ls-remote / API)
=======================================================================

### OpenZFS (modules/open_zfs/openzfs submodule)
- upstream/master pin: gitlink **83020cf8** (= zfs-2.4.3), .gitmodules branch=zfs-2.4.3.
- newest stable release: **zfs-2.4.4** (annotated tag f75f3256 -> commit 71a9f957). Verified
  TODAY: openzfs/zfs has no zfs-2.4.5 / no zfs-2.5.x (2.4.99 is a dev tag, not a release).
- **OPEN PR #1488** (mergeable, non-draft): open_zfs gitlink = **71a9f957** = EXACTLY the
  dereferenced zfs-2.4.4 commit, branch=zfs-2.4.4. Merge-tree CLEAN vs upstream/master.
  => master is exactly one point release behind; the correct newest-stable bump is already
  prepared and correctly pinned in #1488. Maintainer-gated. RISK: low. DID NOT bump.

### lwext4 (modules/lwext4 build-time clone)
- osvunikernel/lwext4 HEAD = **6f6d8f7c** (verified TODAY, unchanged).
- **OPEN PR #1500** (mergeable) pins exactly da1a54a2 whose gitlink target is 6f6d8f7c. Merging
  is a no-op on bits + removes the floating-clone reproducibility hazard. No bump needed. DID NOT touch.

### Other deps: unchanged, deliberate fork/tag pins (musl_1.2.1, musl_0.9.12, acpica, kbuild,
### swagger-ui, osv-gui). No currency action. (acpica is ~13y behind by design - a fact, not drift.)

### FINDING: OpenZFS one release behind (2.4.4 ready+clean in #1488); lwext4 pin ready+clean
### in #1500. Both maintainer-gated. Nothing else warrants a bump. DID NOT bump anything.

=======================================================================
## TASK 4 - Remaining plan (DONE / IN-PROGRESS / NOT-STARTED / BLOCKED)
=======================================================================

Synthesized from ROADMAP, BLOCKED-WINS-LEDGER, QUEUED-FOLLOWUPS, M1-REFRAME, DECLINE-ROOT-CAUSE,
FORK-GENERATION-UPSTREAM-PROPOSAL. Unchanged from the morning sweep except the a2a capstone
progressed from "launched" to "running/setup" and the fork-generation composition proposal is
now POSTED to #1458.

### DONE
- M1 root-cause + writeup: "OSv declines VU8->16->32" headline = substantially a RUN-ORDER
  HARNESS ARTIFACT (never-rebooting harness + a voided clean fresh-boot cell). Fresh-boot VU32 =
  215k (healthy). Real finding = a within-boot fork/teardown wedge (the two leaks). BANKED.
- 11 banked generic fixes, all open + merge-clean, none claimed as M1 parity: #1502 dentry AB-BA,
  #1503 per-chain dentry, #1504 TCB psABI, #1505 ZIL hires, #1506 ARC-max, #1507 fsync scan,
  #1508 physio per-iovec, #1509 per-queue completion, #1472 wake-pull. (#1501 idle-spin, #1510
  ext4 remain DRAFT.)
- Leak #1 (fd/gfdt EMFILE): root-caused + FIXED + 400-round-A/B-validated; review-ready on
  gh-fork bank/fork-fd-reap-leak-reviewready. Blocked only on the fork-stack landing path.
- Leak #2 (fork-arena memory leak): REAL FIX COMPLETE + 5-gate-validated (400 rounds / 26,181
  backends); banked gh-fork bank/fork-arena-real-reclaim (8 cross-AS-object scopings + per-AS
  overflow reclaim). Supersedes the grow-mitigation. Same fork-stack landing dependency.
- Reviewer hygiene: all human review points on all PRs addressed (Task 1).
- P0.1 #1449 ext4 security rebase; P0.2 #1447->pr/ext4-perf-v2 functional part.
- #1478 native-ZFS runtime data pool: OPEN, non-draft, mergeable, merge-clean - the full 6-change
  superset carrying 4a's zfsdev_init change. Effectively DONE + filed (maintainer-gated).

### IN-PROGRESS (do NOT touch - owned by other agents)
- a2a CAPSTONE benchmark (agent-a2afinal, boxes i-005c5bfb.../i-0aee60ad...): RUNNING, in the
  setup phase (.local/a2a-final has host-setup.sh + env + empty cells/raw; NO verdict file yet).
  This is THE open measurement: with wedges/leaks gone + the artifact removed, does OSv scale to
  PG parity, or does the recycle-latency/wakeup deficit cap it? Base = bank/fork-arena-real-reclaim
  (both leak fixes + 8 coherence scopings + 9 perf markers), fresh-boot-per-cell, OSv vs Linux
  m5d.metal, VU8/16/32/64. Awaiting the curve + parity verdict.
- Leak #2 real fix: root-cause CONFIRMED app-lifetime (99.87% PG AllocSet); fix banked + gated.
- OSV_IDLE_SPIN #1501 verdict: SECONDARY (run-order reframe swamped it). Isolate win stands.

### BLOCKED (maintainer offline - every merge blocks on that)
- Merge of master-eligible clean PRs: #1502/#1503/#1504 + #1464 (APPROVED) + the ready standalone
  family (#1477/#1479-#1486/#1490-#1499/#1505-#1509 etc). All merge-clean, non-fork-gated.
- Clear #1439 stale CHANGES_REQUESTED (everything answered).
- #1488 (OpenZFS 2.4.4) + #1500 (lwext4 pin) + #1478 (native data pool): clean, gated.
- #1455/#1456 fork composition (a maintainer DESIGN decision) = the KEYSTONE blocker. Gates the
  fork stack (#1445 NUMA-pools, #1475 COW-nested, #1458 tracking, and BOTH leak fixes' landing
  path). The S1..S8 composition proposal is now POSTED to #1458 (comment 5718101962), awaiting
  the maintainer's composition call.
- P1 p99/latency: no valid p99 base on either ISA (the a2a run in progress will produce the
  clean fresh-boot-per-cell base).

### NOT STARTED
- **M2 / PGXN** (every PostgreSQL extension works OSv == Linux): NOT STARTED. Next major phase
  once M1/leaks conclude. Same dlopen/ELF surface.
- ext4 #1510 re-measurement: DRAFT pending a re-measure on a valid base (functional part done).
- NixOS bench-host flake: directive NixOS>Debian>Fedora; the pinned flake is not built (Debian 12
  AMI current default host).

### #1501 keep-or-close decision (brief flagged as pending):
Leaning KEEP as an isolate-perf PR on its own merit - the recycle-latency/wakeup deficit it
targets is a real, separate thing from the M1-artifact reframe. It stays DRAFT. This is an
operator judgment call, not something to change unilaterally. FLAGGED.

### NOTE on honesty: M1 parity is NOT demonstrated; it is characterized to a root (wakeup latency
### + two fork/teardown leaks, both now fixed+banked). The a2a capstone will test parity directly.
### Banked fixes stand on their own merit. M2 is next regardless.

=======================================================================
## TASK 5 - Draft-PR currency vs upstream
=======================================================================

- upstream/master VERIFIED still **0e34e4dc2** (git fetch upstream = no movement). local master,
  gh-fork/master, origin/master ALL at 0e34e4dc2 (fork mirrors NOT behind).
- Because upstream is UNMOVED, this sweep introduces NO new conflicts.

Merge-tree (--write-tree --messages, upstream/master vs every open PR head, by EXIT CODE).
**48 CLEAN, 8 CONFLICTING - IDENTICAL set to the morning sweep:**

- **#1440 inotify / #1449 ext4 heap-overflow** - TRIVIAL base-drift: conflict ONLY in
  modules/tests/Makefile (the `tests += ...so` line). A rebase re-appends the test line. Not substantive.
- **#1438 / #1441 / #1445 NUMA family** - SUBSTANTIVE: conflict in core/numa.cc + include/osv/numa.hh
  (+ modules/tests/Makefile; + tests/tst-numa.cc for #1441). master gained a92c44f9b (numa: discover
  topology from ACPI SRAT/SLIT) after these branched. Needs a real rebase onto the new NUMA layer.
  #1445 is also fork-stack-adjacent.
- **#1456 / #1475 fork COW stack** - libc/signal.cc + modules/tests/Makefile (#1456 also auto-merges
  core/mmu.cc / include/osv/mmu.hh / linux.cc / runtime.cc clean). Fork-stack dependent (blocked on
  #1455/#1456 composition). DO NOT TOUCH.
- **#1458 tracking PR** - many files (loader.cc, virtio-balloon.cc, libc/signal.cc, Makefile,
  modules/open_zfs/*, scripts/upload_manifest.py, tests/tst-zfs-trim.cc, modules/tests/Makefile).
  Expected for the DO-NOT-MERGE tracking unit. Leak/tracking. DO NOT TOUCH.

### FINDING: upstream unmoved -> no NEW conflicts. Conflicts unchanged from the morning sweep
### (#1440/#1449 trivial; #1438/#1441/#1445 substantive NUMA rebase; #1456/#1475/#1458 fork-stack/
### tracking, owned/blocked). DID NOT rebase/force-push. Temp refs/prheads/* fetched for the scan
### were deleted after use.

=======================================================================
## TASK 6 - Sync local osv + osv-apps
=======================================================================

### osv (~/ws/osv)
- `git fetch upstream --prune` done (read-only). upstream/master 0e34e4dc2 UNMOVED.
- local master, gh-fork/master, origin/master ALL at 0e34e4dc2 - fork mirrors NOT behind.
- Working branch = wip/pg-rx-directwake (report only; not merged/rebased).

### osv-apps (checkout at ~/ws/osv/apps)
- `git fetch --all --prune` done (origin/codeberg/gh-upstream/gh-fork/cloudius).
- checkout HEAD = **3f93f43** on branch pr/phony-build-and-io-method-comment (unchanged).
- cloudius/master = **b2d53b34** (unmoved).
- divergence of 3f93f43 vs cloudius/master: **2-ahead / 655-behind** (unchanged). Both ahead
  commits touch only postgres18-musl (seed_copy fix + shadowed-build-target/io_method note) -> a
  future rebase stays clean.
- **osv-apps #73 (postgres18-musl demo): CURRENT.** OPEN, DRAFT (held on OSv fork/COW landing),
  headRefOid = 3f93f43 = EXACTLY our checkout pin. Verified.

### FINDING: everything current. Master + fork mirrors at 0e34e4dc2; apps gitlink current;
### osv-apps #73 pin matches checkout; clean future rebase. Fetch + report only, no merge/rebase.

=======================================================================
## TASK 7 - Open PRs for finished + unblocked features
=======================================================================

### FINDING: NO PR opened. No standalone + merge-clean + validated candidate exists.

- The morning sweep already retired native-ZFS 4a as SUPERSEDED by open PR #1478 (which carries
  4a's exact zfsdev_init change PLUS the 4 supporting pieces that make it functional). Confirmed
  again this sweep. Do NOT open 4a.
- gh-fork bank/* branches are ALL the leak work (bank/fork-arena-*, bank/fork-fd-reap-leak*) -
  fork-stack-dependent, blocked on #1455/#1456, brief-named off-limits. Cannot open (rule).
- 4b RDSEED: fold into #1492/#1493 after #1492 review settles - do NOT open a competing PR.
- NUMA family rebase (#1438/#1441/#1445): substantive SRAT/SLIT rebase, not a new PR.
- Everything else DONE + validated is ALREADY open (the 11 banked fixes, #1478, #1488, #1500,
  #1459, etc.).

### Did NOT open/validate anything: bar not met; the fork-stack-gated wins are explicitly off-limits.

=======================================================================
## TASK 8 - Local + LAN tidiness
=======================================================================

### Worktrees (osv)
`git worktree list` = 12 (main + 11 linked). ALL directories PRESENT on disk; `git worktree
prune --dry-run` = no-op (0 prunable). NEW since the morning sweep:
- .local/worktrees/a2afinal-base [bank/fork-arena-real-reclaim @ 43fcdca79] = the a2a-final
  agent's base worktree. OFF-LIMITS. NOT touched.
- .local/worktrees/fork-arena [integ/pg-fork-arena @ 858dd78f2] = the LEAK work. NOT touched.
- /tmp/rxpool-wt [rxpool-fix @ 859210d54] = a LIVE linked worktree carrying branch state; LEFT.
All 11 linked worktrees load-bearing (open PR / active branch lines). 0 pruned, 0 prunable.

### /tmp scratch
df: / and /tmp = 3.7T, **40% used, 2.1T free**. NO space pressure.
- All /tmp `*leak*` files (aio_leakrun.sh, build_leak, clean_leaks.py, leak_diag.c, leakhunt-ip,
  leakhunt-patch, leakteeth*.sh, n1_leak.log, ...) = ACTIVE leak agent's. OFF-LIMITS. NOT touched.
- `fork-668e59e.tar.gz`, `forkgen.txt`, `pgw/pgd/pgfix.tar.gz`, the `.s.PGSQL.*` sockets (all
  dated today 07:xx-13:05) = the active leak/fork/PG work. NOT touched.
- No OSv-sweep-dead scratch found. (opstats/ssi/gi/fa/wtail/gc-wt/recno/mvcc/getnext + libdb/
  solnix files are NOT ours; not touched.)
This sweep created NO /tmp scratch (all git/gh/aws read-only).

### EC2 (AWS_PROFILE=lava, account 769093516156)
- Launched ZERO boxes. Owner=agent-maintsweep3 instances/volumes = 0 in us-east-2/us-east-1/us-west-2.
- **0 available (unattached) volumes** in all three regions. No orphans of mine.
- Running instances (NONE mine - report only, NOT touched):
    - i-005c5bfb32d8f12aa a2afinal-metal (agent-a2afinal, m5d.metal, launched 2026-09-17T16:58) +
      i-0aee60adbbece9746 a2afinal-drv (agent-a2afinal, c5.4xlarge, 2026-09-17T16:58) = the LIVE
      a2a capstone. NAMED off-limits. LEFT UNTOUCHED (no ssh, no terminate).
    - i-0679adb07e2726497 libdb-pin + i-0ffbba33b0b0b174e libdb-convoy (c7i.24xlarge x2) = libdb
      project, not OSv, not mine. LEFT.
    - i-05a781e7db035ae74 solnix-imagep (c5.4xlarge) = solnix project, not OSv, not mine. LEFT.
- LAN hosts touched: NONE.

### FINDING: worktrees all present + load-bearing (0 pruned/prunable); no OSv-sweep-dead scratch;
### no space pressure; 0 EC2 of mine + 0 orphans + 0 available volumes. The two OSv boxes running
### are the a2a-final agent's - left untouched per brief.

=======================================================================
## CHANGES MADE THIS SWEEP (safe + clearly-correct only)
=======================================================================
1. git fetch upstream --prune (osv) + git fetch --all --prune (osv-apps) - read-only sync.
2. Fetched all 56 open PR heads into refs/prheads/* for merge-tree checks, then DELETED all of
   them + the temporary pr1488tmp branch (local-only, cleaned up).
3. Wrote this report.

NOT done (by rule / needs operator judgment):
- No reviewer reply posted (0 unanswered comments; no reply to the #1458 proposal).
- No PR opened (Task 7 bar not met; 4a obsoleted by #1478; fork-stack wins off-limits).
- No rebase / force-push (conflicts reported only).
- No merge (all maintainer-gated).
- No /tmp deletion (nothing OSv-sweep-dead; live leak/a2a/PG files present), 0 worktrees pruned.
- Did NOT touch the leak or a2a work (#1458, bank/fork-*, bench/leakhunt, core/fork_arena.cc,
  .local/leak2, .local/a2a-final, the fork-arena + a2afinal-base worktrees, the two a2afinal boxes).
- Did NOT bump any dependency.

=======================================================================
## ITEMS NEEDING YOUR JUDGMENT (flagged)
=======================================================================
A. **#1439:** clear the stale CHANGES_REQUESTED (everything answered through 2026-08-01) - maintainer only.
B. **Merge the clean, ready, maintainer-gated PRs when back:** #1464 (APPROVED) + #1502/#1503/#1504
   first; then #1488 (OpenZFS 2.4.4) + #1500 (lwext4 pin) + #1478 (native data pool); then the
   ready standalone family (#1449 security, #1477, #1479-#1486, #1490-#1499, #1505-#1509).
C. **#1455/#1456 fork composition** = the keystone. The S1..S8 proposal is POSTED to #1458 and
   awaiting your/the maintainer's composition call - it unblocks BOTH banked leak fixes.
D. **#1438/#1441/#1445 NUMA family:** need a real rebase onto master's SRAT/SLIT layer (a92c44f9b) -
   substantive. Do when picking up the NUMA thread.
E. **4b RDSEED:** fold into #1492/#1493 (do NOT open a competing PR) after #1492 review.
F. **#1501 (IDLE_SPIN) keep-or-close:** leaning KEEP as a standalone isolate-perf PR (the
   recycle-latency deficit is real + separate from the M1 reframe). Left DRAFT; your call.
G. **a2a capstone in flight:** the parity verdict is pending (running, no result file yet). It is
   THE open measurement of whether the fix arc yields parity-or-faster OSv/PG-on-ZFS.
