# OSv Maintenance Sweep #3 - 2026-08-26 (later)

Scope: PR + dependency + upstream-issue + hygiene sweep of the OSv fork.
READ/TRIAGE/REPORT + safe git-hygiene only. No heavy builds/benchmarks. No AWS
termination. No public PR-head force-pushes. No fork-trilogy changes.

Environment verified live:
- upstream = cloudius-systems/osv @ `0e34e4dc2b278b7f64e4169abbf297b7de46fb6b`
  (freshly fetched; UNCHANGED since sweeps #1 and #2).
- gh-fork = github.com/gburd/osv-1 ; origin = codeberg gregburd/osv (private).
- SSH agent live (`s.G51mYHxCd5.sshd.81XdjH5vg6`), signing key
  `greg@burd.me-signing-floki-202604` loaded; `%G?`==G verified available.
- gh CLI authed as gburd.

**Continuity:** builds on `.local/MAINT-REPORT.md` (#1), `.local/MAINT-REPORT-2.md`
(#2), `.local/MAINT-PR-ACTIONS.md`. This is a near-pure NO-OP verification round:
upstream/master did not move, no new reviewer/bot comments landed on any PR, and
the items opened last sweep (#1482 numa-harden, #1424 crucible un-block, osv-apps
`wip/postgres18-musl-demo-synced`) are all still good. Nothing new was pushed or
opened this pass because nothing became newly actionable.

---

## Task 1 - PR triage (all open PRs authored by gburd)

**31 open PRs** (was 30 in sweep #2; +1 = #1482 numa-harden, opened by sweep #2's
PR-actions and verified still OPEN/MERGEABLE this pass). **There is NO CI on
cloudius-systems/osv** (`gh pr checks` = no checks for every PR); review is human
(nyh, wkozaczuk) + the Copilot bot only. So the only flags are mergeability and
unaddressed review comments.

| PR | draft | GH mergeable | notes |
|----|-------|--------------|-------|
| 1482 numa-harden | no | MERGEABLE | opened sweep #2; head 144d016fe; 0 comments; still clean |
| 1481 nvme-int-coalescing | no | MERGEABLE | on master tip; ready |
| 1480 condvar-wake-lock | no | MERGEABLE | on master tip; ready |
| 1479 nvme-queue-depth | no | MERGEABLE | on master tip; ready |
| 1478 openzfs-runtime-datapool | no | MERGEABLE | head 25bde6b96; cv_timedwait_hires clock-base follow-up already committed; ready |
| 1477 setlocale-fix | no | MERGEABLE | on master tip; ready |
| 1476 idle-spin-tunable | **DRAFT** | MERGEABLE | deliberately DRAFT (ROADMAP ITEM 5) |
| 1475 fork-cow-nested-lockfree | **DRAFT** | CONFLICTING | FORK TRILOGY - not touched (gated) |
| 1472 sched-idle-pull | no | MERGEABLE | behind 2; banked |
| 1471 nitro-inbound-tcp | no | MERGEABLE | behind 2; banked |
| 1470 virtio-net-rss | no | MERGEABLE | behind 15; banked |
| 1467 net-batch-wakeup | no | MERGEABLE | behind 17; review addressed; banked |
| 1465 msix-vector-budget | no | MERGEABLE | behind 17; banked |
| 1464 sched-load-balance | no | MERGEABLE | nyh APPROVED (2026-08-03); banked; closest to merge |
| 1463 virtio-net-multiqueue | no | MERGEABLE | behind 15; banked |
| 1461 rng-reseed-on-resume | no | MERGEABLE | review addressed; 1 open nyh DESIGN question; banked |
| 1459 openzfs-aarch64 | no | MERGEABLE | on master tip; gated behind #1455 trilogy |
| 1458 integ/pg-fork-zfs | **DRAFT** | CONFLICTING | FORK TRILOGY tracking, DO-NOT-MERGE - not touched (gated) |
| 1456 fork-stage2-pr | no | CONFLICTING | FORK TRILOGY - not touched (gated behind #1455) |
| 1455 feat-fork | no | MERGEABLE | **THE GATE**; FORK TRILOGY - not touched (behind 17); banked |
| 1450 sec-driver-backend | no | MERGEABLE | Copilot items addressed in tip; banked |
| 1449 sec-ext4-readlink | no | CONFLICTING | GH stale-flag; rebases clean; review fixes applied; banked |
| 1447 ext4-perf | **DRAFT** | CONFLICTING | STACKED on #1431 |
| 1445 numa-per-node-pools | **DRAFT** | CONFLICTING | STACKED on #1441; numa.cc superseded by master |
| 1444 virtio-net-ipv6-offload | **DRAFT** | MERGEABLE | STACKED on #1442 fwd-port |
| 1442 ipv6-forward-port | no | MERGEABLE (stale-tree) | needs real net-stack forward-port |
| 1441 numa-alloc | no | CONFLICTING | numa.cc now on master; Copilot items superseded |
| 1440 inotify | no | CONFLICTING | GH stale-flag; rebases clean; Copilot addressed; banked |
| 1439 signalfd | no | MERGEABLE (flag CHANGES_REQUESTED, stale) | all review addressed; banked |
| 1438 numa-mempolicy | no | CONFLICTING | numa.cc now on master; Copilot items superseded |
| 1424 crucible | no | MERGEABLE | un-blocked/body-fixed sweep #2; head cdb02c912; ready |

### Unresolved reviewer / bot comments

**NO new reviewer or bot comment has landed on any PR since sweep #2.** I pulled
the newest comment/review timestamp for every open PR: the latest non-gburd
signal anywhere is **nyh's APPROVED review on #1464 (2026-08-03)**; every newer
entry is gburd's own comment. The maintainer remains offline (as expected until
~November).

Every Copilot/nyh finding across the PR set was already fixed-in-code or
answered by sweeps #1/#2 (verified there for #1439/#1440/#1450/#1455/#1461/#1464
/#1467/#1449). The only remaining review-thread items are NOT mechanically
actionable:
- **#1461** - nyh's open design question (is the kvmclock.cc resume detector
  redundant given the random.cc detector?). A design dialogue awaiting nyh; a
  draft reply is banked in MAINT-REPORT.md. Not auto-posted (avoids churn; the
  maintainer is offline).
- **#1438/#1441** - Copilot's numa parse_srat/parse_slit findings apply to code
  that is now UPSTREAM (a92c44f9b), not to the dead PR branches. Sweep #2 already
  filed the correct fix as a fresh master-side hardening PR (**#1482**, still
  open/mergeable). Nothing further owed on the PR branches.

**Flags:**
- (a) merge-conflicting vs master: #1475, #1458, #1456, #1447, #1445, #1441,
  #1438, #1442 (real); #1440 and #1449 show CONFLICTING on GitHub but rebase
  cleanly (stale flag). Real conflicts break down as: numa trio (1438/1441/1445),
  fork-stack (1456/1475/1458), ext4-perf (1447), ipv6 (1442, +1444 stacked).
- (b) failing CI: N/A (no CI on this repo).
- (c) unaddressed review comments: none mechanically actionable (see above).

---

## Task 2 - Mechanical/safe reviewer-comment fixes

**None pushed - none owed.** No new reviewer/bot comment arrived since sweep #2,
and every prior finding is either fixed-in-code, answered, or superseded by
master (and re-filed as #1482). The only lingering items are a design dialogue
(#1461, awaiting nyh) and superseded numa-branch findings (already handled via
#1482). No PR comment was posted (nothing new to report; maintainer offline;
posting would be noise).

---

## Task 3 - Stale-base check + rebases

`git fetch upstream master` done; **upstream/master = `0e34e4dc2`, UNCHANGED**
since sweeps #1/#2 computed all rebases. Because master did not move, the 13
`bank/<n>-<name>-rebased` branches banked to codeberg by sweep #2 are STILL VALID.
Spot-verified live that they sit exactly on the master tip:

- `bank/1464-sched-load-balance-rebased` (2044a9e27): 1 commit ahead of master,
  0 behind, base == master tip. CLEAN.
- `bank/1455-feat-fork-rebased` (6de06ac8e): 5 commits ahead, 0 behind, base ==
  master tip. CLEAN.
- `bank/1439-signalfd-rebased` (480b87194): 1 commit ahead, 0 behind, base ==
  master tip. CLEAN.

Full bank inventory confirmed present on codeberg (origin):
```
bank/1439-signalfd-rebased            bank/1465-msix-vector-budget-rebased
bank/1440-inotify-rebased             bank/1467-net-batch-wakeup-rebased
bank/1449-ext-readlink-rebased        bank/1470-virtio-net-rss-rebased
bank/1450-sec-driver-backend-rebased  bank/1471-nitro-inbound-tcp-rebased
bank/1455-feat-fork-rebased           bank/1472-sched-idle-pull-rebased
bank/1461-rng-reseed-rebased          bank/rx-napi-full  (RX bank, not a PR)
bank/1463-virtio-net-multiqueue-rebased  bank/rx-napi-signed (RX bank, not a PR)
bank/1464-sched-load-balance-rebased
```
Plus the older `mt/1440-inotify-rebased` and `mt/1449-ext-readlink-rebased`.

**No new rebase was banked** (nothing to recompute; master unchanged). **No public
PR head was force-pushed** (rebasing is a rewrite; force-with-lease is hook-blocked
in this environment; delete+recreate of a PR head is forbidden). The banks are
private-mirror staging for a human to fast-forward/force-push when the maintainer
is back. The MERGEABLE-but-behind PRs (#1439/#1450/#1461/#1463/#1464/#1465/#1467/
#1470/#1471/#1472/#1455) still merge clean on GitHub without a rebase, so a rebase
is not required for them.

**Conflicting PRs needing a real forward-port (human, unchanged from #1/#2):**
- numa trio #1438/#1441/#1445 - SRAT/SLIT discovery is now on master (a92c44f9b);
  branches carry a superseded copy. Not a rebase - a forward-port. The hardening
  half was already delivered as **#1482**.
- ipv6 #1442 (+#1444 stacked) - real FreeBSD net-stack forward-port
  (routecache.hh / tcp_input.cc / net_channel.cc).
- ext4-perf #1447 - stacked on #1431; conflicts; rebase after its base.
- fork-stack #1456/#1475/#1458 - gated behind #1455; NOT touched.

---

## Task 4 - External dependency currency (report-only, no bumps)

| dep | how pinned | our pin | upstream latest | update? |
|-----|-----------|---------|-----------------|---------|
| **OpenZFS** | submodule `modules/open_zfs/openzfs` | master gitlink `83020cf8` = **zfs-2.4.3** (`.gitmodules branch=zfs-2.4.3`); our LOCAL wip working-tree gitlink `6330a45b` = zfs-2.4.2 (branch lag, harmless) | **zfs-2.4.4** (latest 2.4.x tag; re-checked live via `git ls-remote --tags` - no newer 2.4.x exists; 2.4.99 is a dev tag) | **Report-only.** Master is 1 patch behind stable (2.4.3 vs 2.4.4). A bump = re-apply the OSv patch stack on 2.4.4 + a validated ZFS boot/pool test. Do NOT bump. Unchanged from sweep #2. |
| **musl_1.2.1** | submodule `osvunikernel/musl` fork | `73cc775` = fork v1.2.1 | canonical musl v1.2.6 | **Blocked/backlog.** OSv builds its own patched musl fork; a 1.2.x bump is a large deliberate fork-rebase (CVE/printf/locale). Out of scope. |
| **musl_0.9.12** | submodule `cloudius-systems/musl` | `372a948b` | legacy | Frozen legacy variant. No action. |
| **acpica** | submodule `cloudius-systems/acpica` fork | `3e45e0f2` | fork tip == pin | Current with OSv's frozen 2013 fork. No drift. |
| **kbuild** | submodule `osvunikernel/kbuild-standalone` | `9f1d27a8` | fork master | Current. No action. |
| **Crucible** | no submodule/pin (from-scratch driver, PR #1424) | ProtocolVersion::V13 | upstream MessageVersion V13 | **Current.** Hand-implemented wire protocol matches upstream V13. No action. |

**Net:** only latent item = OpenZFS 2.4.3->2.4.4 (report-only, needs validated
patch rebase). musl 1.2.x fork-rebase remains backlog. Nothing blocks the
in-flight PRs. Unchanged since sweep #2.

---

## Task 5 - Upstream issues/PRs we filed against external projects

- **gkostka/lwext4 #100** ("Out-of-bounds read: ext4_ext_check() does not bound
  eh_max/eh_entries to block capacity", author gburd, filed 2026-07-14): re-checked
  live - **state OPEN, 0 comments, updatedAt still 2026-07-14T14:24:21Z** (no
  maintainer reply). Upstream dormant (last push 2024-03-22). Non-blocking (fix
  lives in the osvunikernel/lwext4 fork OSv builds; OSv-side hardening is PR #1449).
  No action available.
- **openzfs/zfs**: confirmed NO issue/PR authored by gburd. The 20+ openzfs/zfs
  issue URLs found in `.local` are third-party research references (spot-checked:
  #16631 by Rudd-O, #17277 by 1JorgeB) cited for patch provenance, NOT filed by us.
  The OpenZFS-on-OSv fixes are platform-layer patches in `modules/open_zfs/patches/`,
  not upstream OpenZFS bugs.
- **musl / Crucible**: none filed (fork patches / from-scratch driver).
- **cloudius-systems/osv #1474** (our own OpenZFS known-failing-tests tracker):
  OPEN, 0 comments. #1423 (the PR it documents) is merged, so the gap-doc landed
  on master. Keep open.

**Net:** one external report (lwext4 #100), open + unanswered against a dormant
repo, non-blocking. Nothing actionable. Unchanged since sweeps #1/#2.

---

## Task 6 - Plan completeness (ROADMAP + HANDOFF + status notes)

Read ROADMAP.md, HANDOFF.md, unfinished-plan-status.md, upstream-issues-status.md.
(There is no `.local/pg-osv-milestones.md`; milestone state lives in ROADMAP.md +
unfinished-plan-status.md.)

### (a) BLOCKED on maintainer (offline til ~Nov - no self-serve action)
- **#1455 fork()/vfork()/execve()/waitpid()** - THE GATE. OPEN, mergeable-clean,
  reviewed (design dialogue answered). Blocks the whole stack.
- Gated behind #1455: **#1456** (per-child COW AS), **#1458** (PG+ZFS integ,
  DRAFT tracking), **#1459** (openzfs aarch64), **#1475** (fork-COW-lockfree,
  DRAFT). Fork trilogy - NOT touched this pass.
- **~18 clean/mergeable feature PRs** awaiting review bandwidth: 1477, 1478, 1479,
  1480, 1481, 1482, 1424, 1450, 1439, 1461, 1463, 1464 (APPROVED), 1465, 1467,
  1470, 1471, 1472, 1442 (stale-tree). Blocker is human review, not code.
- **M2 / PGXN packaging** - downstream of fork trilogy (#1455 gate) + #1423
  (merged). Not startable now.

### (b) BLOCKED on our-work (focused session, not the maintainer)
- **numa trio #1438/#1441/#1445** - numa.cc merged to master (a92c44f9b); branches
  carry a superseded copy and need a forward-port. Hardening half already delivered
  as #1482.
- **#1442 IPv6 forward-port** (+#1444 stacked) - real net-stack forward-port.
- **#1447 ext4-perf** - stacked on #1431; rebase after its base.
- **OpenZFS 2.4.3->2.4.4** bump (validated patch-stack rebase + ZFS boot test).
- **vn_access superuser fix** (gh-fork pr/vfs-superuser-access) and
  **native-zfs-fixes** (gh-fork wip/native-zfs-fixes): both rebase clean, both
  staged, both need a KVM-metal ZFS-boot validation before opening a PR (the fs=zfs
  cpiod image-populate fails under nested QEMU-TCG without KVM). Blocked on metal
  access, not code.

### (c) READY to do (mechanical, low-risk)
- Fast-forward/force-push the 13 banked `bank/*` rebases (+ prior `mt/*`) onto
  their gh-fork PR heads - a human with force-push rights, when rebasing is wanted.
  Not urgent (GitHub merges the clean ones un-rebased).
- #1482 numa-harden: ready for review whenever the maintainer returns.

### Known blockers (explicit, per the task)
1. **fork+dlopen HammerDB crash** - the fork/dlopen path under the HammerDB
   workload (open in the benchmark agents' work; a live fork-debug agent
   `osv-forkdbg` is on it right now - see Task 11).
2. **per-commit / per-request wake latency** - the residual ~4x gap to Linux at
   c16+ is the process-per-connection wake floor (structural, documented in
   WAKE-INLINE-RESULT.md; idle-spin + wake-inline closed the halt-exit + deep-tail
   portions). Not a missing fix.
3. **OpenZFS 2.4.4 bump** - report-only, needs a validated patch-stack rebase.
4. **numa/IPv6 forward-ports** - #1438/#1441/#1445 (numa; hardening done as #1482)
   and #1442/#1444 (IPv6) need real forward-ports onto merged master code.
5. **Crucible** - #1424 is technically un-blocked (all 3 blockers merged) and was
   un-drafted/body-fixed in sweep #2; awaiting maintainer review.

### Scale/perf state (informational, benchmark agents own this)
PG-on-OSv mid-range scaling largely solved (MQ+RSS+idle-CPU-PULL+fork-COW+idle-spin
+wake-inline). Residual = fork-per-backend structural cost. Native EC2 boot + PG
serving reached. ZFS read-path zero-copy ARC<->pagecache bridge (borrow-page shim
built but unwired) is the top open code-study lever. Owned by benchmark agents.

---

## Task 7 - Draft PRs

| PR | can un-draft now? | reason |
|----|-------------------|--------|
| **#1476** idle-spin-tunable | **No - keep DRAFT** | ROADMAP ITEM 5: reframe as perf-neutral halt-VM-exit-reduction efficiency/tunability change; the +% is host-halt-poll-dependent (no stable universal number). Mergeable/clean but deliberately draft. |
| **#1475** fork-cow-nested-lockfree | **No** | FORK TRILOGY - gated (stacked on #1456, behind #1455). CONFLICTING. Not touched. |
| **#1458** integ/pg-fork-zfs | **No** | FORK TRILOGY tracking/DO-NOT-MERGE. Gated. Not touched. |
| **#1447** ext4-perf | **No** | STACKED on #1431; CONFLICTING; can't un-draft until base merges + rebases. |
| **#1445** numa-per-node-pools | **No** | STACKED on #1441; CONFLICTING; numa.cc superseded - needs numa forward-port first. |
| **#1444** virtio-net-ipv6-offload | **No** | Mergeable-clean itself but STACKED on #1442 which needs a net-stack forward-port. |

**No draft was un-drafted.** The only non-gated draft is #1476, deliberately held
per ITEM 5. Fork-trilogy drafts (#1475/#1458) explicitly not touched.

---

## Task 8 - Validated-feature PRs

**No new PR opened this pass** - no finished feature became newly validated +
unblocked + rebase-clean + leak-clean since sweep #2.

- **OpenZFS runtime-datapool #1478 + follow-ons**: verified all still healthy and
  MERGEABLE - #1478 (head 25bde6b96, with the `cv_timedwait_hires` wall-clock/
  absolute-deadline follow-up already committed), #1479 (nvme-queue-depth), #1480
  (condvar-wake-lock), #1481 (nvme-int-coalescing). All clean, on/near master tip,
  ready for review. Nothing to open (they are already PRs).
- **vn_access superuser fix** (gh-fork pr/vfs-superuser-access @ eeed07edf): cherry-
  picks clean, build+boot+ramfs-test validated in sweep #1, BUT the ZFS-specific
  reproduction could not run on-target (fs=zfs cpiod populate fails under nested
  QEMU-TCG without KVM). **Ready to PR pending a KVM-metal ZFS repro.** Not opened.
- **native-zfs-fixes** (gh-fork wip/native-zfs-fixes @ 1600b68cb): 2 commits
  (zfsdev_init on --preload-zfs-library; RDSEED/TSC boot-seed) rebase clean. Same
  KVM-metal ZFS-boot validation gate. **Ready to PR pending X (KVM-metal validation).**
  Not opened.
- **wake-local safety guard / cv_timedwait_hires wall-clock fix**: the
  cv_timedwait_hires clock-base fix is already IN #1478 (committed follow-up). No
  separate standalone PR warranted.

Per the rule "VALIDATE MEANS BUILD+BOOT+TEST; do NOT open a PR on an unvalidated
branch", the two staged branches stay staged until a human runs the ZFS repro on
KVM-metal. Documented, not opened.

---

## Task 9 - osv-apps sync

- The branch `wip/postgres18-musl-demo-synced` (created sweep #2's PR-actions,
  tip c5c1790) is **still clean: 0 behind / 3 ahead of cloudius/master**.
- **cloudius/master is UNCHANGED at `b2d53b348`** (same as sweep #2) - so there are
  NO new upstream apps changes since last sweep. The synced branch remains current.
- The original `wip/postgres18-musl-demo` (unscrubbed) and the synced (scrubbed)
  branch both coexist on gh-fork osv-apps; not touched this pass.
- The in-tree `apps` submodule gitlink is at its working state (`M apps` marker on
  the wip working branch; the RX agent's working tree) - NOT git-add'd, per HANDOFF.

**No merge/rebase done** (report-only; nothing new upstream to sync).

---

## Task 10 - Local + LAN hygiene

### (a) In /home/gburd/ws/osv
- **`git worktree prune --dry-run`: nothing to prune.** All 21 worktree entries
  point at existing directories: `.local/worktrees/*` are the active PR worktrees
  (batchwake, close-range, ena-rss, fork-arena, forksym, inotify, ipv6-port, numa,
  numa-alloc, numa-mempolicy, pg-fork-zfs, sched-lb, scrub-aarch64, sec-driver,
  sec-ext4-readlink, sigmq-fixed, sigmq-substrate, signalfd, vnet6); `/tmp/rxpool-wt`
  (protected RX-agent worktree) exists on disk. No dead /tmp entries.
- Working branch `wip/pg-rx-directwake` and its dirty working tree (M apps,
  M core/net_channel.cc, M drivers/virtio-vring.hh, M include/osv/net_channel.hh,
  ?? .agent/) - the RX agent's in-flight work - NOT touched.
- No tracked files, `.local` notes, or branches deleted.

### (b) /tmp on this host
- **Removed (safe, regenerable scratch from finished sessions):**
  - 45 gdb thread-dump scripts `/tmp/g*.gdb` (Aug 25, a finished debug session).
  - `/tmp/apps-check` (my own throwaway osv-apps clone created THIS session for
    the Task 9 check; not a registered git worktree). Removed via `rm -r` (no -f).
- **LEFT (a LIVE agent is actively writing these RIGHT NOW):** `/tmp/fbuild.sh`,
  `/tmp/fsetup.sh`, `/tmp/qgdb.sh`, `/tmp/storm.sh` (all timestamped 17:04-17:07,
  minutes old), plus the HammerDB `.tcl` drivers `/tmp/build.tcl`,
  `/tmp/run_{1,8,16,32,64}.tcl`, `/tmp/hdb-build.tcl`, `/tmp/build.sh`,
  `/tmp/mkrun.sh`. These belong to the running `osv-forkdbg` fork-debug agent
  (see Task 11) - NOT touched per the "other agents own builds/benchmarks" rule.
- **KEPT (protected):** `/tmp/gitsign` (signing config), `/tmp/rxpool-wt` (live
  git worktree, RX agent).
- **No secrets found:** no `/tmp/creds.txt` or `*cred*`/`*secret*` scratch. The
  `.pem` files listed by ssh-add are ssh-agent-loaded keys, not deletable scratch.

### (c) LAN
- No other LAN hosts under our control. The only RUNNING osv-* box is a live
  benchmark/debug agent's (`osv-forkdbg`, see Task 11) - reported, NOT touched.

---

## Task 11 - AWS inventory (AWS_PROFILE=chiuso, us-east-2, READ-ONLY)

**Nothing created, terminated, or deleted.**

**RUNNING instances (6) - all LEFT untouched:**
| id | type | name | launch | key | disposition |
|----|------|------|--------|-----|-------------|
| i-017543e11f90c6d24 | m5d.metal | **osv-forkdbg** | 2026-08-26 17:03 | osv-rxval | **OURS, but a LIVE fork-debug agent is using it** (matches the minutes-old /tmp scratch). Per the rule (a benchmark/debug agent may be live), NOT touched - reported only. |
| i-0393e90bc0c2c7b54 | i4i.8xlarge | pgtv-gist10m | 2026-08-26 15:59 | pgtv-2v0-... | other project (pgtv), left |
| i-0c4f4fab83f62a460 | c7i.4xlarge | xtc-py-20260826-... | 2026-08-26 16:58 | xtc-py-... | other project (xtc), left |
| i-0090923a68a462a40 | c7i.4xlarge | flux-clean-bench | 2026-08-25 08:19 | flux-bench-key | other project (flux), left |
| i-0d62b4aadb9e186d2 | m5.4xlarge | solnix-desktop-gburd | 2026-08-25 09:27 | chiuso-key | other project (solnix), left |
| i-0d24c0ec7a9a0e109 | m5.4xlarge | solnix-arm64-kernel | 2026-08-26 12:29 | chiuso-key | other project (solnix), left |

**AVAILABLE (unattached) volumes: 51 - NONE named/tagged osv-*.** All untagged
(50) build-fleet scratch (matches the solnix timeline; 50->51 since sweep #2). Per
the task rule they are NOT osv-* so NOT our candidates - report only. They are >2h
old and accruing cost, but attribution is ambiguous (untagged). **Flag for the
solnix-fleet owner / human:** ~51 untagged available volumes accumulating in
us-east-2. Deleted NOTHING.

**Self-owned AMIs: 19, ALL solnix-*. Zero named osv-*.** Left.

**Self snapshots: 31, ALL solnix-* descriptions. Zero described osv-*.** Left.

**Net:** 1 running osv-* box = a LIVE fork-debug agent (not touched). 0 osv-*
volumes/AMIs/snapshots. 0 orphans of ours. Terminated/deleted nothing.

---

## SUMMARY

**PRs needing action / what I addressed:** Nothing was mechanically actionable.
Upstream/master is unchanged (`0e34e4dc2`), NO new reviewer/bot comment landed on
any of the 31 open PRs since sweep #2, and every prior finding is fixed/answered/
superseded. I posted no comments and pushed no code (posting would be noise; the
maintainer is offline til ~Nov). The only open review item is #1461's design
dialogue (awaiting nyh; draft reply banked). #1438/#1441 numa findings are already
handled via the master-side hardening PR **#1482** (verified still OPEN/MERGEABLE).

**PRs opened/edited this pass:** NONE. Verified still-good from sweep #2: #1482
(numa-harden, OPEN/MERGEABLE, 0 comments), #1424 (crucible, OPEN/MERGEABLE/not-
draft, body already fixed), osv-apps `wip/postgres18-musl-demo-synced` (0 behind
cloudius/master). #1478 + follow-ons (#1479/#1480/#1481) all clean/MERGEABLE.

**External-dep status:** OpenZFS latest stable = **2.4.4** (master pins 2.4.3, 1
behind) - report-only, needs a validated patch rebase. musl 1.2.x fork-rebase =
backlog. acpica/kbuild/musl-forks current. Crucible driver == upstream V13. No
bumps done.

**Upstream-issue status:** lwext4 #100 (only external issue we filed) still OPEN,
0 comments, unchanged, dormant upstream, non-blocking. No openzfs/musl/Crucible
issues filed by us. Our tracker osv#1474 still OPEN. Nothing actionable.

**Plan remaining (categorized):**
- (a) blocked-on-maintainer: #1455 gate + fork stack (#1456/#1458/#1459/#1475) +
  M2/PGXN + ~18 clean PRs awaiting review (incl. #1464 APPROVED, #1424, #1482).
- (b) blocked-on-our-work: numa forward-port (#1438/#1441/#1445; hardening done as
  #1482), IPv6 forward-port (#1442/#1444), ext4-perf rebase (#1447), OpenZFS 2.4.4
  bump, KVM-metal ZFS validation of vn_access + native-zfs-fixes.
- (c) ready-to-do: force-push the 13 banked rebases when wanted; #1482 review.
- Known blockers: fork+dlopen HammerDB crash (a live osv-forkdbg agent is on it),
  per-request wake latency (structural floor), OpenZFS 2.4.4, numa/IPv6 forward-
  ports, Crucible (un-blocked, awaiting review).

**What I cleaned locally:** 45 finished-session gdb thread dumps (`/tmp/g*.gdb`,
Aug 25) + my own throwaway `/tmp/apps-check` clone (this session). Left ALL
today-dated scratch (a live fork-debug agent is writing `/tmp/fbuild.sh` /
`fsetup.sh` / `qgdb.sh` / `storm.sh` and the HammerDB `.tcl` files minute-by-
minute). Kept `/tmp/gitsign` + `/tmp/rxpool-wt`. No worktrees pruned (none dead).
No tracked files / `.local` notes / branches deleted. No force-push, no un-draft,
no merge, no pin bump.

**AWS inventory:** 6 running instances (1 = our LIVE osv-forkdbg fork-debug box,
NOT touched; rest solnix/flux/pgtv/xtc - all other projects, left). 0 osv-*
volumes/AMIs/snapshots. 51 untagged available volumes (not ours; flagged for the
solnix-fleet owner). Terminated/deleted nothing.

**This was a NO-OP verification round:** nothing moved upstream, nothing new
became actionable, so nothing was pushed or opened. All sweep #1/#2 work verified
intact.
