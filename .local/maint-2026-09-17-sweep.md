# OSv upstreaming maintenance/tidy sweep - 2026-09-17

READ-heavy sweep, building on the 2026-09-16 sweep (.local/maint-2026-09-16-sweep.md).
Did NOT touch the in-flight leak work: bench/leakhunt, bank/fork-fd-reap-leak*,
bank/fork-arena-grow-mitigation, bank/fork-arena-real-reclaim, core/fork_arena.cc,
PR #1458, .local/leak2, .local/leak1-pr, the fork-arena worktree. Agent e7245ce6
owns the leak #2 real-fix work RIGHT NOW on box i-0a13d716cee541d70 (confirmed LIVE).

Environment: SSH agent /run/user/1000/wezterm/agent.3913155. AWS lava profile WORKS
this sweep (account 769093516156, us-east-2) - unlike 2026-09-16 which had no creds.

HEADLINE DELTA vs 2026-09-16: exactly ONE material change - native-ZFS 4a is now
SUPERSEDED by already-open PR #1478 (see Task 7). Everything else is unchanged:
upstream still 0e34e4dc2, 0 new reviewer comments, deps current (2.4.4 in #1488 /
lwext4 pin in #1500), osv-apps #73 pin current, no new conflicts, 0 EC2 of mine.

=======================================================================
## TASK 1 - PR reviewer comments/issues
=======================================================================

Scanned all 56 open gburd PRs three ways (issue-comments API, pulls inline-comments
API, pulls reviews API), filtering bots (copilot/[bot]) and gburd himself.

### FINDING: 0 new reviewer activity since 2026-09-14. Nothing to reply to.

- ZERO non-bot, non-gburd issue-comments after 2026-09-14.
- ZERO non-bot, non-gburd inline review comments after 2026-09-14.
- ZERO non-bot, non-gburd reviews after 2026-09-14.
- Newest human (nyh/wkozaczuk) activity ANYWHERE is still 2026-08-03:
    #1464 nyh APPROVED 2026-08-03T14:29; #1455 wkozaczuk 08-03; #1461 nyh 08-03;
    #1463 wkozaczuk 08-01; #1439 nyh CHANGES_REQUESTED 2026-07-15.
  No reviewer has returned since. Every post-09-14 PR touch is gburd's own or the
  leak agent's (#1458 updated 2026-09-17T12:00 = the leak agent's step-1 update).

### Two flagged PRs, re-verified:
- **#1439 signalfd (CHANGES_REQUESTED): CONFIRMED STILL STALE.**
  reviewDecision=CHANGES_REQUESTED, mergeable=MERGEABLE, not draft. All 8 review
  threads resolved=true, every one lastBy=gburd (last 2026-08-01). nyh's flag was
  never cleared but there is nothing substantive outstanding. Maintainer-gated.
- **#1464 load-balancer disperse (APPROVED): CONFIRMED.**
  reviewDecision=APPROVED, mergeable=MERGEABLE, not draft. 6 review threads,
  unresolved but each lastBy=gburd (last 2026-09-09T14:06 = his reply to the
  cpus.size()*8 cap question). Awaiting maintainer merge.

No reply drafted or posted (there is nothing to reply to). No nudge (maintainer
offline; do-not-nudge per prior triage).

=======================================================================
## TASK 2 - Upstream-filed dependency issues/PRs (external projects)
=======================================================================

### FINDING: only lwext4 #100 outstanding; STILL no activity, none expected. Null.

- **gkostka/lwext4 #100** ("Out-of-bounds read: ext4_ext_check() does not bound
  eh_max/eh_entries to block capacity"): OPEN, **0 comments, updated_at STILL
  2026-07-14T14:24:21Z** (unchanged since filing, now across five checks). gkostka
  upstream last push 2024-03-22 (dormant) - no reply expected. Our fix ships in the
  osvunikernel/lwext4 fork OSv builds from and is also OSv PR #1449. Non-blocking.
  ACTION: none available. Leave open as the good-citizen report.
- **openzfs/zfs**: `gh search issues --author gburd --repo openzfs/zfs` = EMPTY.
  Nothing filed. (The ~40 openzfs URLs in .local are cited prior-art, not our
  filings - verified they are not authored by gburd.)
- Full external `author:gburd` search returns ONLY lwext4 #100 outside
  cloudius-systems/*. osv-apps #71/#73 (our own fork) covered in Task 6; #72 merged.
- Nothing filed at qemu, musl, acpica, firecracker (each verified 0).

=======================================================================
## TASK 3 - External dependency currency (verified TODAY via git ls-remote / API)
=======================================================================

### OpenZFS (modules/open_zfs/openzfs submodule)
- upstream/master pin: gitlink **83020cf8 = zfs-2.4.3**, .gitmodules branch=zfs-2.4.3.
- newest stable release: **zfs-2.4.4** (71a9f957). Verified TODAY: openzfs/zfs has
  no zfs-2.4.5 and no zfs-2.5.x on any ref (2.4.99 is a dev tag, not a release).
- **OPEN PR #1488** (mergeable, not draft): open_zfs gitlink = 71a9f957 = EXACTLY
  the zfs-2.4.4 tag commit, branch=zfs-2.4.4. Merge-tree CLEAN vs upstream/master.
  So master is exactly one point release behind, and the correct newest-stable bump
  is already prepared + correctly pinned in #1488. Maintainer-gated.
- RISK: low. The prior sweep proved #1488's single upstream-edits patch applies to a
  real 2.4.4 checkout (exit 0, with-teeth). DID NOT bump.

### lwext4 (modules/lwext4 build-time clone)
- osvunikernel/lwext4 HEAD = **6f6d8f7c** (verified TODAY, unchanged).
- **OPEN PR #1500** (mergeable) pins exactly 6f6d8f7c. Merging is a no-op on bits and
  removes the floating-clone reproducibility hazard. No bump needed. DID NOT touch.

### Other deps (unchanged from the 2026-09-11 deps-currency.md bank, re-confirmed)
- musl_1.2.1 -> v1.2.1 tag (deliberate; 1.2.x rebase is standing backlog, not a task).
- musl_0.9.12 / acpica / kbuild / swagger-ui / osv-gui: deliberate fork/tag pins, no
  currency action flagged. (acpica fork is ~13y behind real ACPICA by design - a
  fact, not a drift.)

### FINDING: OpenZFS one release behind (2.4.4 ready+clean in #1488); lwext4 pin
### ready+clean in #1500. Both maintainer-gated. Nothing else warrants a bump.
### DID NOT bump anything.

=======================================================================
## TASK 4 - Remaining plan (DONE / IN-PROGRESS / NOT-STARTED / BLOCKED)
=======================================================================

Synthesized from ROADMAP.md, NORTH-STAR, PROGRAM-STATE, M1-REFRAME-LANDMARK,
DECLINE-ROOT-CAUSE-FOUND, QUEUED-FOLLOWUPS. Unchanged from 2026-09-16 except leak #2
advanced (root-cause CONFIRMED app-lifetime) and native-ZFS 4a retired (Task 7).

### DONE
- M1 root-cause + writeup: the "OSv declines VU8->VU16->VU32" headline was
  substantially a RUN-ORDER HARNESS ARTIFACT (never-rebooting harness + a voided
  clean fresh-boot cell). Fresh-boot VU32 = 215k, healthy. Real finding = a
  within-boot fork/teardown wedge (the two leaks). Characterization BANKED.
- 11 banked generic fixes, all filed open + merge-clean, none claimed as M1 parity:
  #1502 dentry AB-BA, #1503 per-chain dentry, #1504 TCB psABI, #1505 ZIL hires,
  #1506 ARC-max, #1507 fsync scan, #1508 physio per-iovec, #1509 per-queue
  completion, #1472 wake-pull. (#1501 idle-spin, #1510 ext4 remain DRAFT.)
- Leak #1 (fd/gfdt): root-caused + FIXED + A/B-validated (400 rounds; gfdt flat vs
  climbs-to-65535 EMFILE@224). Banked on gh-fork bank/fork-fd-reap-leak +
  bank/fork-fd-reap-leak-reviewready. [Leak worker owns - not touched.]
- Reviewer hygiene: all human review points on all PRs addressed (Task 1).
- P0.1 #1449 ext4 security rebase; P0.2 #1447->pr/ext4-perf-v2 (functional part).
- #1478 native-ZFS runtime data-pool: OPEN, non-draft, mergeable - the full 6-change
  superset (see Task 7). Effectively DONE + filed (maintainer-gated to merge).

### IN-PROGRESS (do NOT touch - agent e7245ce6, LIVE on i-0a13d716cee541d70)
- Leak #2 REAL fix: root-cause CONFIRMED via histogram (2026-09-17) - the leak is
  APP-LIFETIME (99.87% PostgreSQL AllocSet/MemoryContext heap; 0.13% libc wrappers;
  ZERO from kernel-lifetime sites -> all vfs objects already kernel_heap_scope'd).
  Prior "missed nested kernel scope" hypothesis cleanly REFUTED by data. Fix = per-AS
  overflow region with NO-OP free via BSS range-check, wholesale reclaim on reap;
  proceeding to build + the 5-part gate (mem flat + no wedge to 300 + CORRUPT=0 +
  cross-AS-kernel-object-survival probe). FIVE prior reclaim designs refuted (data,
  not failure). Leak #1 remains fixed+banked (blocked only on the fork-stack landing).
- OSV_IDLE_SPIN #1501 verdict: SECONDARY (reframe showed run-order swamped it). Isolate
  win stands; #1501 stays DRAFT.

### BLOCKED (maintainer offline; every merge blocks on that)
- Merge of the master-eligible clean PRs: #1502/#1503/#1504 + #1464 (APPROVED), plus
  the ready standalone family (#1477/#1479-#1486/#1490-#1499/#1505-#1509 etc). All
  merge-clean, non-fork-gated. BLOCKED on maintainer.
- Clear #1439 stale CHANGES_REQUESTED. BLOCKED on maintainer.
- #1488 (OpenZFS 2.4.4) + #1500 (lwext4 pin) + #1478 (native data-pool): clean,
  BLOCKED on maintainer.
- #1455/#1456 fork composition (a maintainer DESIGN decision). Blocks the fork stack
  (#1445 NUMA-pools, #1475 COW-nested, #1458 tracking, and both leak fixes' landing
  path - leak #1 is review-ready but has no upstream base until this decides).
- P1 p99/latency: no valid p99 base on either ISA (reframe voids the contaminated
  curve; needs a clean fresh-boot-per-cell OSv-vs-Linux base).
- Firecracker-on-current-base: not reached (budget + quota). AWS lava quota WAS 5 vCPU
  with a 200-vCPU request open; a metal launch needs the increase. (Note: metal boxes
  ARE running now on lava - see Task 8 - so the quota may have been granted; verify
  before assuming still-blocked. I did not launch to test.)

### NOT STARTED
- **M2 / PGXN** (every PostgreSQL extension works OSv == Linux): NOT STARTED. The next
  major phase once M1/leaks conclude. Same dlopen/ELF surface.
- ext4 #1510 re-measurement: DRAFT pending a re-measure on a valid base (functional
  part done, perf numbers not re-validated).
- NixOS bench-host flake: directive is NixOS>Debian>Fedora for the bench HOST; the
  pinned flake is "build it" = NOT built (Debian 12 AMI is current default host).

### NOTE on honesty
M1 parity is NOT demonstrated; it is characterized to a root (wakeup latency + two
fork/teardown leaks). Banked fixes stand on their own merit. M2 is next regardless.

=======================================================================
## TASK 5 - Draft-PR currency vs upstream
=======================================================================

- upstream/master VERIFIED still at **0e34e4dc2** (tip dated 2026-08-17T12:19, the
  #1423 OpenZFS squash-merge; git fetch upstream confirms unmoved). local master,
  gh-fork/master, origin/master all at 0e34e4dc2 (fork mirrors NOT behind).
- Because upstream is UNMOVED, this sweep introduces NO new conflicts.

Merge-tree (--write-tree --messages) of every open PR head vs upstream/master.
**48 of 56 CLEAN; 8 CONFLICTING - IDENTICAL set to 2026-09-16:**

- **#1440 inotify / #1449 ext4 heap-overflow** - TRIVIAL base-drift: conflict ONLY in
  modules/tests/Makefile (the `tests += ...so` line collides with master's later
  test additions). #1449 also auto-merges ext_vnops.cc clean. A rebase re-appends the
  test line. Not substantive.
- **#1438 / #1441 / #1445 NUMA family** - SUBSTANTIVE: conflict in core/numa.cc +
  include/osv/numa.hh + linux.cc/loader.cc (+ tests/tst-numa.cc for #1441). master
  gained `a92c44f9b numa: discover topology from ACPI SRAT/SLIT` after these branched
  (confirmed: a92c44f9b is on master's core/numa.cc history). Needs a real rebase onto
  the new upstream NUMA layer, not a re-append. #1445 is also fork-stack-adjacent.
- **#1456 / #1475 fork COW stack** - core/mmu.cc + mmu.hh + libc/signal.cc +
  linux.cc + runtime.cc. Fork-stack dependent (blocked on #1455/#1456 composition).
  DO NOT TOUCH.
- **#1458 tracking PR** - many files (elf/mmu/pagecache/virtio*/zfs etc). Expected for
  the DO-NOT-MERGE tracking unit. Leak worker owns. DO NOT TOUCH.

### FINDING: upstream unmoved -> no NEW conflicts. Conflicts unchanged from
### 2026-09-16 (#1440/#1449 trivial; #1438/#1441/#1445 substantive NUMA rebase;
### #1456/#1475/#1458 fork-stack/tracking, owned/blocked). DID NOT rebase/force-push.

=======================================================================
## TASK 6 - Sync local osv + osv-apps
=======================================================================

### osv (~/ws/osv)
- `git fetch --all --prune` done (origin/upstream/gh-fork).
- upstream/master 0e34e4dc2 UNMOVED. local master, gh-fork/master, origin/master ALL
  at 0e34e4dc2 - fork mirrors NOT behind. (Working branch wip/pg-rx-directwake;
  report only, not merged/rebased.)

### osv-apps (checkout at ~/ws/osv/apps)
- `git fetch --all --prune` done (origin/codeberg/gh-upstream/gh-fork/cloudius).
- checkout HEAD = **3f93f43** on branch pr/phony-build-and-io-method-comment (UNCHANGED
  from 2026-09-16).
- cloudius/master = **b2d53b34** (unmoved). master's `apps` gitlink = b2d53b348 =
  EXACTLY cloudius/master -> master submodule pointer current.
- divergence of 3f93f43 vs cloudius/master: **655-behind / 2-ahead** (unchanged); a
  future rebase stays clean (none of the 655 touch postgres18-musl).
- **osv-apps #73 (seed_copy/phony-build fix): CURRENT.** OPEN, DRAFT (held on OSv
  fork/COW landing), headRefOid = 3f93f43 = EXACTLY our checkout pin. Verified.
  (#71 ec2-audit idle; #72 io-uring-bench closed/merged.)

### FINDING: everything current. Master + fork mirrors at 0e34e4dc2; apps gitlink
### current; osv-apps #73 pin matches checkout; clean future rebase. Report only.

=======================================================================
## TASK 7 - Open PRs for finished + unblocked features
=======================================================================

### FINDING: NO PR opened. The one previously-flagged candidate (native-ZFS 4a) is
### now SUPERSEDED by already-open #1478. No standalone+clean+validated candidate exists.

### *** MATERIAL CHANGE vs the 2026-09-16 sweep ***
The 2026-09-16 sweep recommended "open native-ZFS 4a standalone after a metal
fs=ramfs -> zpool validation" (commit 59f4f12ad on gh-fork wip/native-zfs-fixes).
**That recommendation is now WRONG and is retracted.** Direct diff comparison shows:

- 4a's entire change = "call zfsdev::zfsdev_init() (opt_init-gated) on the
  --preload-zfs-library path" in loader.cc (+21/-2).
- **OPEN PR #1478** ("zfs(openzfs): enable a runtime ZFS data pool on a non-ZFS-root
  image", non-draft, MERGEABLE, merge-tree CLEAN vs upstream/master) contains 4a's
  exact zfsdev_init lambda as its change #1, PLUS the pieces 4a LACKS and NEEDS:
    #2 RTLD_GLOBAL so the userspace zpool/zfs tools resolve libsolaris's ~60 nvpair
       symbols (without it the tools report missing symbols + "/dev/zfs not found");
    #3 create /etc/mnttab (the tools consult it);
    #4 MOVE the preload BEFORE the root-mount block - because after the unmount/pivot
       the libsolaris path is no longer dlopen-able. 4a leaves the preload AFTER the
       pivot, which #1478's own comment documents as the reason a late preload FAILS.
    #5 carry the libsolaris.so manifest entry on the provider module;
    #6 nanosecond cv_timedwait_hires for ZIL coalescing.
- => Opening 4a standalone would be a strict SUBSET of #1478 and would actually be
  NON-FUNCTIONAL on its own (late preload fails). It is obsoleted. Do NOT open it.
  The correct disposition: 4a lands via #1478 (maintainer-gated). wip/native-zfs-fixes
  4a can be treated as retired.

### 4b RDSEED (commit 1600b68cb) - unchanged disposition
Still overlaps the same drivers/random.cc early-read region as #1492 (RDRAND early
/dev/random, OPEN/non-draft/mergeable/no-review-yet) and #1493 (aarch64 RNDR). Fold
RDSEED into #1492 (or a follow-on stacked on it) AFTER #1492 review settles - do NOT
open a competing PR. Not a standalone opener.

### Other candidates (QUEUED-FOLLOWUPS)
- NUMA family rebase (#1438/#1441/#1445): substantive SRAT/SLIT rebase, not a new PR.
- Leak #1/#2: fork-stack-dependent, blocked on #1455/#1456 - do NOT open (rule).
- Everything else DONE+validated is ALREADY open (the 11 banked fixes, #1478, #1488,
  #1500, #1459, etc.).

### Did NOT metal-validate/open anything: the only candidate that would have needed a
### metal run (4a) turned out to be obsoleted by #1478, so no validation was warranted.

=======================================================================
## TASK 8 - Local + LAN tidiness
=======================================================================

### Worktrees (osv)
`git worktree list` = 11 (main + 10 linked). ALL directories present; `git worktree
prune --dry-run` = no-op (0 prunable). Notable:
- .local/worktrees/fork-arena [integ/pg-fork-arena @ 858dd78f2] = the LEAK work.
  NOT touched.
- /tmp/rxpool-wt [rxpool-fix @ 859210d54] = a LIVE linked worktree carrying branch
  state. NOT dead scratch. LEFT AS-IS (deleting would strand the checkout).
All 10 linked worktrees load-bearing (match open PR / active branch lines). 0 pruned.

### /tmp scratch
df: / and /tmp = 3.7T, **40% used, 2.1T free**. NO space pressure.
- Recent (Sep 16-17) /tmp `*leak*` files (leakteeth*.sh, rq6/rq7_leak.sh, n1_leak.log,
  aio_leakrun.sh, leakhunt-ip, leakhunt-patch, fork-668e59e.tar.gz) = the ACTIVE leak
  agents' files. DO NOT TOUCH. Left.
- Older (Sep 5-15) small OSv helper scripts (lwbpipe-*.sh, osv_*.sh, osvrun*.sh) =
  tiny build/run helpers; ambiguous ownership, ~8-15 days old, could be referenced by
  a running workflow. No space benefit to deleting; LEFT (lazy-safe: reclaims nothing
  meaningful, risks live work).
- 0 qemu/loop/losetup procs of mine running.
This sweep created NO /tmp scratch (all git/gh/aws read-only). Nothing OSv-sweep-dead.

### EC2 (AWS_PROFILE=lava, account 769093516156, us-east-2 - creds WORK this sweep)
- I launched ZERO boxes this sweep. Owner=agent-maintsweep2 instances/volumes/AMIs = 0.
- **0 available (unattached) volumes** in us-east-2 (and none in us-east-1/us-west-2,
  which are empty). No orphans of mine.
- Running instances (NONE mine - report only, NOT touched):
    - i-0a13d716cee541d70 osv-leak2real (agent-leak2real, m5d.metal) = LIVE leak #2
      agent's box. NAMED off-limits in the brief. CONFIRMED live, LEFT UNTOUCHED.
    - i-0192356debe7b635c fts-abc-* (r6id.4xlarge), i-072c/0679/0ffb libdb-* (c7i.24xl
      x3), i-0107c850 solnix-dixibuild (m5.8xl) = OTHER projects (fts, libdb, solnix),
      not OSv, not mine. LEFT.
- LAN hosts touched: NONE.
- NOTE: metal (m5d.metal) is running on lava, so the 5-vCPU quota that blocked metal
  in the ROADMAP appears to have been raised (200-vCPU request granted). Flag for the
  Firecracker-on-current-base item, which was quota-blocked.

### FINDING: worktrees all present + load-bearing (0 pruned/prunable); no OSv scratch
### to clean; no space pressure; 0 EC2 of mine + 0 orphans + 0 available volumes; the
### one OSv box (leak2real) is the live leak agent's, left untouched.

=======================================================================
## CHANGES MADE THIS SWEEP (safe + clearly-correct only)
=======================================================================
1. git fetch --all --prune on osv and osv-apps; git fetch upstream (read-only sync).
2. Fetched all 56 open PR heads into refs/prheads/* for merge-tree checks (local only).
3. Wrote this report.

NOT done (by rule / needs your judgment):
- No reviewer reply posted (0 unanswered comments).
- No PR opened (Task 7 bar not met; 4a is now obsoleted by #1478, not openable).
- No rebase / force-push (conflicts reported only).
- No merge (all maintainer-gated).
- No /tmp deletion (nothing OSv-sweep-dead; live leak files present), 0 worktrees pruned.
- Did NOT touch the leak work (#1458, bank/fork-*, bench/leakhunt, core/fork_arena.cc,
  .local/leak2, .local/leak1-pr, the fork-arena worktree, box i-0a13d716cee541d70).
- Did NOT bump any dependency.

=======================================================================
## ITEMS NEEDING YOUR JUDGMENT (flagged)
=======================================================================
A. **native-ZFS 4a is superseded by #1478 - retire it.** The 2026-09-16 flag "open 4a
   after metal validation" is retracted: #1478 (open/mergeable) already carries 4a as
   change #1 plus 4 more pieces 4a needs to actually work, and standalone 4a would be
   non-functional. No new PR. Merge #1478 (maintainer) to land 4a's fix.
B. **Merge the clean, ready, maintainer-gated PRs when back:** #1464 (APPROVED) +
   #1502/#1503/#1504 first; then #1488 (OpenZFS 2.4.4) + #1500 (lwext4 pin) + #1478
   (native data-pool); then the ready standalone family (#1449 security, #1477, #1479-
   #1486, #1490-#1499, #1505-#1509).
C. **#1439:** clear the stale CHANGES_REQUESTED (everything answered) - maintainer only.
D. **#1438/#1441/#1445 NUMA family:** need a real rebase onto master's SRAT/SLIT layer
   (a92c44f9b) - substantive, not trivial. Do when picking up the NUMA thread.
E. **4b RDSEED:** fold into #1492/#1493 (do NOT open a competing PR) after #1492 review.
F. **Quota:** metal is running on lava now, so the metal-blocking 5-vCPU quota may be
   lifted - re-check before treating Firecracker-on-current-base as quota-blocked.
