# OSv Maintenance Sweep #4 - 2026-08-27

Scope: PR + dependency + upstream-issue + hygiene sweep of the OSv fork.
READ/TRIAGE/REPORT + safe git-hygiene only. No heavy builds/benchmarks. No AWS
termination. No public PR-head force-pushes. No fork-trilogy changes.

Environment verified live:
- upstream = cloudius-systems/osv @ `0e34e4dc2b278b7f64e4169abbf297b7de46fb6b`
  (freshly fetched; UNCHANGED since sweeps #1/#2/#3).
- gh-fork = github.com/gburd/osv-1 ; origin = codeberg gregburd/osv (private).
- SSH agent live (`s.G51mYHxCd5.sshd.81XdjH5vg6`), signing key
  `greg@burd.me-signing-floki-202604` (SHA256:H31vk...) loaded; `%G?`==G verified.
- gh CLI authed as gburd. `gpg.ssh.allowedSignersFile` set to /tmp/gitsign/allowed_signers.

**Continuity:** builds on `.local/MAINT-REPORT.md` (#1), `MAINT-REPORT-2.md` (#2),
`MAINT-REPORT-3.md` (#3), `MAINT-PR-ACTIONS.md`. Like sweep #3 this is a near-pure
NO-OP verification round: upstream/master did not move, no new reviewer/bot comment
landed on any PR, and the items opened by sweeps #2/#3 (#1483, #1482, #1424, osv-apps
`wip/postgres18-musl-demo-synced`) are all still good. Nothing new was pushed or
opened because nothing became newly actionable. Local /tmp cleaned of dead scratch.

---

## Task 1 - PR triage (all open PRs authored by gburd)

**32 open PRs** (was 31 in sweep #3; +1 = **#1483** pagecache-munmap-sync-nothrow,
created between sweeps #3 and #4 as part of the fork-fix-chain work). **There is NO
CI on cloudius-systems/osv** - review is human (nyh, wkozaczuk) + the Copilot bot
only. The only flags are GitHub mergeability and unaddressed review comments.

| PR | draft | mergeable | notes |
|----|-------|-----------|-------|
| 1483 pagecache-munmap-sync-nothrow | no | MERGEABLE | **NEW since #3**; head c3f882094; single signed commit on master tip; 3-file focused diff; 0 comments; leak-clean. Verified healthy this pass. |
| 1482 numa-harden | no | MERGEABLE | opened sweep #2; head 144d016fe; 0 comments; still clean |
| 1481 nvme-int-coalescing | no | MERGEABLE | on master tip; ready |
| 1480 condvar-wake-lock | no | MERGEABLE | on master tip; ready |
| 1479 nvme-queue-depth | no | MERGEABLE | on master tip; ready |
| 1478 openzfs-runtime-datapool | no | MERGEABLE | cv_timedwait_hires follow-up committed; ready |
| 1477 setlocale-fix | no | MERGEABLE | on master tip; ready |
| 1476 idle-spin-tunable | **DRAFT** | MERGEABLE | deliberately DRAFT (ROADMAP ITEM 5) |
| 1475 fork-cow-nested-lockfree | **DRAFT** | CONFLICTING | FORK TRILOGY - not touched (gated) |
| 1472 sched-idle-pull | no | MERGEABLE | banked |
| 1471 nitro-inbound-tcp | no | MERGEABLE | banked |
| 1470 virtio-net-rss | no | MERGEABLE | banked |
| 1467 net-batch-wakeup | no | MERGEABLE | review addressed; banked |
| 1465 msix-vector-budget | no | MERGEABLE | banked |
| 1464 sched-load-balance | no | MERGEABLE | nyh APPROVED (2026-08-03); banked; closest to merge |
| 1463 virtio-net-multiqueue | no | MERGEABLE | banked |
| 1461 rng-reseed-on-resume | no | MERGEABLE | review addressed; 1 open nyh DESIGN question; banked |
| 1459 openzfs-aarch64 | no | MERGEABLE | on master tip; gated behind #1455 trilogy |
| 1458 integ/pg-fork-zfs | **DRAFT** | CONFLICTING | FORK TRILOGY tracking, DO-NOT-MERGE - not touched (gated) |
| 1456 fork-stage2-pr | no | CONFLICTING | FORK TRILOGY - not touched (gated behind #1455) |
| 1455 feat-fork | no | MERGEABLE | **THE GATE**; FORK TRILOGY - not touched; banked |
| 1450 sec-driver-backend | no | MERGEABLE | Copilot items addressed in tip; banked |
| 1449 sec-ext4-readlink | no | CONFLICTING | GH stale-flag; **re-verified rebases clean this pass**; review fixes applied; banked |
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

**NO new reviewer or bot comment has landed on any PR since sweep #3.** Pulled the
newest non-gburd comment/review timestamp for every open PR: the latest signal
anywhere is **nyh's APPROVED review on #1464 (2026-08-03)**; all Copilot reviews
are pre-2026-08-04; every newer entry is gburd's own comment. Maintainer offline
(as expected until ~November).

Spot-verified the #1439 review threads at the inline-comment level: every Copilot
finding (7 items) and both nyh inline questions have a matching gburd reply with
the fix committed (headers added, uiomove-then-pop ordering, test blocks signals,
comment softened, SIGKILL/SIGSTOP filtered like Linux, single-reader delivery,
extern-"C" removed). nyh's `signalfd.cc:165` item was a design question ("investigate
Linux behavior") and gburd's reply documents the first-match approximation. Nothing
mechanically actionable remains.

**Flags:**
- (a) merge-conflicting vs master: #1475, #1458, #1456, #1447, #1445, #1441,
  #1438, #1442 (real); #1440 and #1449 show CONFLICTING on GitHub but rebase
  cleanly (stale flag; #1449 re-verified clean this pass). Real conflicts:
  numa trio (1438/1441/1445), fork-stack (1456/1475/1458), ext4-perf (1447),
  ipv6 (1442, +1444 stacked).
- (b) failing CI: N/A (no CI on this repo).
- (c) unaddressed review comments: none mechanically actionable (see above).

---

## Task 2 - Mechanical/safe reviewer-comment fixes

**None pushed - none owed.** No new reviewer/bot comment arrived since sweep #3,
and every prior finding is fixed-in-code (verified at the inline-thread level for
#1439), answered (#1461 design dialogue, awaiting nyh), or superseded by master and
re-filed as #1482 (numa #1438/#1441 findings). The only lingering items are a design
dialogue (#1461) and superseded numa-branch findings (handled via #1482). No PR
comment posted (nothing new; maintainer offline; posting would be noise).

---

## Task 3 - Stale-base check + rebases

`git fetch upstream master` done; **upstream/master = `0e34e4dc2`, UNCHANGED** since
sweeps #1/#2/#3 computed all rebases. Because master did not move, the 13
`bank/<n>-<name>-rebased` branches are STILL VALID. Spot-verified live that they sit
exactly on the master tip (merge-base == master tip):

- `bank/1464-sched-load-balance-rebased` (2044a9e27): merge-base 0e34e4dc2 == master. CLEAN.
- `bank/1455-feat-fork-rebased` (6de06ac8e): merge-base 0e34e4dc2 == master. CLEAN.
- `bank/1439-signalfd-rebased` (480b87194): merge-base 0e34e4dc2 == master. CLEAN.

Full bank inventory confirmed present on codeberg (origin), 15 branches:
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

Additionally re-verified live: **#1449 rebases cleanly on upstream/master** in a
/tmp throwaway worktree (`git rebase upstream/master` -> "Successfully rebased",
no conflicts), confirming its GitHub CONFLICTING is a stale flag. Worktree removed +
pruned.

**No new rebase was banked** (nothing to recompute; master unchanged). **No public
PR head was force-pushed.** The MERGEABLE-but-behind PRs still merge clean on GitHub
without a rebase, so a rebase is not required for them.

**Conflicting PRs needing a real forward-port (human, unchanged from #1/#2/#3):**
- numa trio #1438/#1441/#1445 - SRAT/SLIT discovery now on master (a92c44f9b);
  branches carry a superseded copy. Forward-port, not rebase. Hardening half was
  delivered as #1482.
- ipv6 #1442 (+#1444 stacked) - real FreeBSD net-stack forward-port.
- ext4-perf #1447 - stacked on #1431; rebase after its base.
- fork-stack #1456/#1475/#1458 - gated behind #1455; NOT touched.

---

## Task 4 - External dependency currency (report-only, no bumps)

| dep | how pinned | our pin | upstream latest | update? |
|-----|-----------|---------|-----------------|---------|
| **OpenZFS** | submodule `modules/open_zfs/openzfs` | master gitlink `83020cf8` = **zfs-2.4.3** (verified: peeled tag zfs-2.4.3 == 83020cf8); our LOCAL wip working-tree gitlink `6330a45b` = zfs-2.4.2 (branch lag, harmless) | **zfs-2.4.4** (`71a9f9578`; re-checked live via `git ls-remote --tags` - no newer 2.4.x; 2.4.99 is a dev tag) | **Report-only.** Master is 1 patch behind stable (2.4.3 vs 2.4.4). A bump = re-apply the OSv patch stack on 2.4.4 + a validated ZFS boot/pool test. Do NOT bump. Unchanged from #3. |
| **musl_1.2.1** | submodule `osvunikernel/musl` fork | `73cc775` | fork HEAD `a5aff197` (fork moved); canonical musl v1.2.6 | **Blocked/backlog.** OSv builds its own patched musl fork; the fork tip advanced past our pin but a bump is a large deliberate fork-rebase (CVE/printf/locale). Out of scope. |
| **musl_0.9.12** | submodule `cloudius-systems/musl` | `372a948b` | legacy | Frozen legacy variant. No action. |
| **acpica** | submodule `cloudius-systems/acpica` fork (relative URL) | `3e45e0f2` | fork tip | Current with OSv's frozen fork. No drift. |
| **kbuild** | submodule `osvunikernel/kbuild-standalone` | `9f1d27a8` | fork HEAD `9f1d27a8` (== pin) | Current. No action. |
| **Crucible** | no submodule/pin (from-scratch driver, PR #1424) | ProtocolVersion V13 | upstream MessageVersion V13 | **Current.** Hand-implemented wire protocol matches upstream V13. No action. |

**Net:** only latent item = OpenZFS 2.4.3->2.4.4 (report-only, needs validated patch
rebase). musl 1.2.x fork-rebase remains backlog (fork tip moved but that is a
deliberate rebase decision). kbuild pin == fork HEAD. acpica/musl-forks current.
Nothing blocks the in-flight PRs. Effectively unchanged since sweep #3.

---

## Task 5 - Upstream issues/PRs we filed against external projects

- **gkostka/lwext4 #100** ("Out-of-bounds read: ext4_ext_check() does not bound
  eh_max/eh_entries to block capacity", author gburd, filed 2026-07-14): re-checked
  live - **state OPEN, 0 comments, updatedAt still 2026-07-14T14:24:21Z** (no
  maintainer reply). Upstream dormant (last push 2024-03-22). Non-blocking (fix
  lives in the osvunikernel/lwext4 fork OSv builds; OSv-side hardening is PR #1449).
  No action available.
- **openzfs/zfs / musl / Crucible**: confirmed NO issue/PR authored by gburd (fork
  patches / from-scratch driver). The openzfs/zfs issue URLs in `.local` are
  third-party research references, not filed by us.
- **cloudius-systems/osv #1474** (our own OpenZFS known-failing-tests tracker):
  re-checked - OPEN, 0 comments, updatedAt 2026-08-17. #1423 (the PR it documents)
  is merged. Keep open.

**Net:** one external report (lwext4 #100), open + unanswered against a dormant repo,
non-blocking. Nothing actionable. Unchanged since sweeps #1/#2/#3.

---

## Task 6 - Plan completeness (ROADMAP + HANDOFF + status notes)

Read ROADMAP.md (esp. lines ~2240-2457: the fork+dlopen fix chain, the pagecache
fix, and the fork-teardown NULL-deref blocker), HANDOFF.md, upstream-issues-status.md.
(There is no `.local/pg-osv-milestones.md`; milestone state lives in ROADMAP.md.)

### Active blocker (the M1 HammerDB gate) - the fork resume-context NULL crash

The fork+HammerDB fix chain progressed through 3 crashes (each MEASURED, each got
strictly further):
- **v6**: crashed at concurrent forked-backend dlopen (elf::program::get_library
  page fault - .so segments mapped in the COW app slot 32, private per forked AS,
  while the shared _modules list references per-AS VAs -> cross-AS fault).
- **v7** (commit `f6b07f239`, elf: share dlopen'd segments across fork ASes as
  fork_shared_module_ranges): dlopen crash GONE both bare-metal + Firecracker. Then
  crashed at munmap-writeback (file::sync throw -> C++ unwinder abort in a forked
  backend).
- **v8** (commit `97e7db5d0`, pagecache: munmap writeback error by return not throw):
  munmap-throw crash GONE, guest survives past it. **Now crashes at FORK ADDRESS-SPACE
  TEARDOWN**: the AS0 reaper's `destroy_address_space` (core/mmu.cc:767) NULL-derefs
  (addr=0, vm_sigsegv -> vm_fault) disposing a backend's file_vma (`~file_vma ->
  delete _page_ops`) when a backend that mmap'd relation files exits under HammerDB
  ANALYZE load.

Root cause (from source + gdb backtrace): the fork-shared module ranges shared by
v7's fix must NOT be destroyed as private per-child on teardown (the shared range's
page state is owned by AS0/global). `destroy_address_space` disposes a vma pointing
at a now-shared/already-freed range -> NULL deref. Confirmed by test: simple backend
fork+exit+reap (40x, no mmap-relation) works on v8; the teardown crash needs a
backend that mmap'd a file. This is the teardown counterpart to v7's segment-sharing
fix - deep fork-lifecycle work, fork-stack (#1455) territory. NEXT: fix
`destroy_address_space` to skip freeing fork-shared-range page state per-child. A
live `osv-teardbg` debug box is on it right now (see Task 11).

### (a) BLOCKED on maintainer (offline til ~Nov - no self-serve action)
- **#1455 fork()/vfork()/execve()/waitpid()** - THE GATE. OPEN, mergeable-clean,
  reviewed. Blocks the whole fork stack.
- Gated behind #1455: **#1456** (per-child COW AS), **#1458** (PG+ZFS integ tracking,
  DRAFT), **#1459** (openzfs aarch64), **#1475** (fork-COW-lockfree, DRAFT). Fork
  trilogy - NOT touched.
- **~19 clean/mergeable feature PRs** awaiting review bandwidth: 1477, 1478, 1479,
  1480, 1481, 1482, 1483, 1424, 1450, 1439, 1461, 1463, 1464 (APPROVED), 1465, 1467,
  1470, 1471, 1472, 1442 (stale-tree). Blocker is human review, not code.
- **M2 / PGXN packaging** - downstream of the fork trilogy (#1455 gate). Not startable.
- **elf segment-sharing fix (f6b07f239)** - the fork-stack follow-on PR (share
  dlopen'd library segments across fork ASes). Depends on CONF_fork +
  mmu::add_fork_shared_module_range (fork-stack only). PR it onto the fork stack when
  #1455 is unblocked. Banked on wip/pg-zfs-bench-v8; verified present locally + on
  gh-fork; do not lose it.

### (b) BLOCKED on our-work (focused session, not the maintainer)
- **Fork-teardown NULL-deref** (the M1 HammerDB gate, above) - fix
  `destroy_address_space` to not free fork-shared-range page state per-child. A live
  osv-teardbg agent owns this session now.
- **numa trio #1438/#1441/#1445** - numa.cc merged to master; branches need a
  forward-port. Hardening half delivered as #1482.
- **#1442 IPv6 forward-port** (+#1444 stacked) - real net-stack forward-port.
- **#1447 ext4-perf** - stacked on #1431; rebase after its base.
- **OpenZFS 2.4.3->2.4.4** bump (validated patch-stack rebase + ZFS boot test).
- **vn_access superuser fix** + **native-zfs-fixes** (gh-fork staged branches):
  rebase clean, need a KVM-metal ZFS-boot validation before opening a PR.

### (c) READY to do (mechanical, low-risk)
- Fast-forward/force-push the 13 banked `bank/*` rebases onto their gh-fork PR heads
  - a human with force-push rights, when rebasing is wanted. Not urgent (GitHub
  merges the clean ones un-rebased).
- #1483 (pagecache) + #1482 (numa-harden) + #1424 (crucible): ready for review
  whenever the maintainer returns.

### Scale/perf state (informational, benchmark agents own this)
PG-on-OSv single-backend + moderate-concurrency parity reached (wall-clock cv fix +
ZFS glue). Residual OSv gaps: (1) per-commit wake latency (structural process-per-
connection floor, documented), (2) the fork+dlopen/teardown crash under the many-
short-lived-backend HammerDB pattern (the active blocker). Linux HammerDB baseline
(this session, bare metal, PG16-ZFS, 40wh): ~45k NOPM plateau. OSv NOPM still
blocked by the teardown crash. Owned by benchmark/debug agents.

---

## Task 7 - Draft PRs

| PR | can un-draft now? | reason |
|----|-------------------|--------|
| **#1476** idle-spin-tunable | **No - keep DRAFT** | ROADMAP ITEM 5: the +% is host-halt-poll-dependent (no stable universal number). Mergeable/clean but deliberately draft. |
| **#1475** fork-cow-nested-lockfree | **No** | FORK TRILOGY - gated (stacked on #1456, behind #1455). CONFLICTING. Not touched. |
| **#1458** integ/pg-fork-zfs | **No** | FORK TRILOGY tracking/DO-NOT-MERGE. Gated. Not touched. |
| **#1447** ext4-perf | **No** | STACKED on #1431; CONFLICTING; can't un-draft until base merges + rebases. |
| **#1445** numa-per-node-pools | **No** | STACKED on #1441; CONFLICTING; numa.cc superseded - needs numa forward-port first. |
| **#1444** virtio-net-ipv6-offload | **No** | Mergeable-clean itself but STACKED on #1442 which needs a net-stack forward-port. |

**No draft was un-drafted.** The only non-gated draft is #1476, deliberately held per
ITEM 5; the others depend on an unmerged base forward-port or are the gated fork
trilogy. Fork-trilogy drafts (#1475/#1458) explicitly not touched.

---

## Task 8 - Validated-feature PRs

**No new PR opened this pass** - no finished feature became newly validated + unblocked
+ rebase-clean-on-master + leak-clean since sweep #3 that does NOT depend on
CONF_fork / fork-only machinery.

- **pagecache munmap-sync-nothrow (#1483)**: the ONLY master-eligible fix out of the
  fork-fix chain, and it is ALREADY a PR (opened between #3 and #4). Verified this
  pass: head c3f882094, single signed commit (`%G?`==G, Greg Burd), merge-base ==
  upstream/master tip, 3-file focused diff (core/pagecache.cc + fs/vfs/vfs_fops.cc +
  include/osv/pagecache.hh), body clean, leak-clean (the master version is the clean
  re-authoring - NO em-dashes, unlike the wip commit 97e7db5d0 which also scrubs
  comment em-dashes). Independently valid (master's pagecache::sync still throws on
  munmap regardless of fork). Nothing to open - it is already #1483.
- **elf: share dlopen'd segments across fork AS (f6b07f239)**: **NOT master-eligible**
  per instruction - depends on CONF_fork + mmu::add_fork_shared_module_range which
  live ONLY in the fork stack (#1455, gated). Correctly kept as a FORK-STACK FOLLOW-ON
  on wip/pg-zfs-bench-v8. Verified present locally + on gh-fork. Do NOT PR to master.
- **OpenZFS runtime-datapool #1478 + follow-ons (#1479/#1480/#1481)**: verified still
  healthy/MERGEABLE. Already PRs.
- **vn_access superuser fix** (gh-fork pr/vfs-superuser-access) + **native-zfs-fixes**
  (gh-fork wip/native-zfs-fixes): both rebase clean, both need a KVM-metal ZFS-boot
  validation before opening a PR (fs=zfs cpiod populate fails under nested QEMU-TCG
  without KVM). **Ready pending KVM-metal ZFS validation.** Not opened.

Per the rule "VALIDATE MEANS BUILD+BOOT+TEST; do NOT open a PR on an unvalidated
branch", nothing new was opened. Documented, not opened.

---

## Task 9 - osv-apps sync

- Branch `wip/postgres18-musl-demo-synced` (tip `c5c1790`) re-verified in a /tmp
  throwaway clone: **0 behind / 3 ahead of cloudius/master**, and its 3 commits touch
  ONLY `postgres18-musl/` (zero overlap with upstream's app dirs). Clean.
- **cloudius/master is UNCHANGED at `b2d53b348`** (same as sweeps #2/#3) - so there
  are NO new upstream apps changes since last sweep. The synced branch remains current.
- The original `wip/postgres18-musl-demo` (unscrubbed, tip c0d2bad) and the synced
  (scrubbed) branch both coexist on gh-fork osv-apps; not touched.
- The in-tree `apps` submodule gitlink shows `M apps` on the wip working branch (the
  RX agent's working tree) - NOT git-add'd, per HANDOFF.

**No merge/rebase done** (report-only; nothing new upstream to sync). Throwaway clone
removed.

---

## Task 10 - Local + LAN hygiene

### (a) In /home/gburd/ws/osv
- **`git worktree prune --dry-run`: nothing to prune.** All 21 worktree entries point
  at existing directories: `.local/worktrees/*` are the active PR worktrees (batchwake,
  close-range, ena-rss, fork-arena, forksym, inotify, ipv6-port, numa, numa-alloc,
  numa-mempolicy, pg-fork-zfs, sched-lb, scrub-aarch64, sec-driver, sec-ext4-readlink,
  sigmq-fixed, sigmq-substrate, signalfd, vnet6); `/tmp/rxpool-wt` (protected RX-agent
  worktree) exists on disk. No dead /tmp entries.
- Working branch `wip/pg-rx-directwake` and its dirty working tree (M apps,
  M core/net_channel.cc, M drivers/virtio-vring.hh, M include/osv/net_channel.hh,
  ?? .agent/ .claude/ .envrc .local/ AGENTS.md HANDOFF.md external/openzfs/
  musl_1.1.24/) - the RX agent's in-flight work + untracked notes - NOT touched.
- No tracked files, `.local` notes, or branches deleted.

### (b) /tmp on this host
- **Removed (safe, regenerable, clearly-mine scratch from finished sessions), via
  `rm -r` (no -f):**
  - `/tmp/pi-bash-e8c7e8edc9b7f220.log` (312M - my own bash tool log, regenerable)
  - `/tmp/reb1449.log` (my own this-session rebase-check output)
  - Aug 24-25 gdb/probe scratch from finished sessions (no active writer):
    `gscan.py`, `gzscan.py`, `gcvscan.py`, `gzil2.py`, `qmon_read.py`, `qmon.sh.local`,
    `sample.py`, `sshcmd`, `loader.elf-gdb.py`, `bake.py`, `gdbcmds`, `gdbcmds2`,
    `gdbcmds3`.
  - (~312MB reclaimed, dominated by the bash log.)
- **LEFT (a LIVE agent is actively writing these RIGHT NOW - the osv-teardbg
  fork-teardown debug session, files timestamped 04:35-05:12 today):** `rungdb.sh`
  ... `rungdb8.sh`, `gdb.cmds` ... `gdb8.cmds`, `runqemu.sh`, `dobuild.sh`, `sshosv`
  (references the TD box IP), `pgsync-body.md` (the #1483 PR-body draft). The
  `ssh_mux_18.118.166.170_*` control socket confirms an open session to the TD box.
- **LEFT (Aug 26 bake/build/HammerDB scratch a live debug agent may re-source):**
  `rb8.sh`, `bld.tcl`, `v7bake.sh`, `rebuild7.sh`, `storm.sh`, `qgdb.sh`, `fbuild.sh`,
  `fsetup.sh`, `run_{1,8,16,32,64}.tcl`, `mkrun.sh`, `build.tcl`, `hdb-build.tcl`,
  `fc.json`, `fc2.json`, `build.sh`. Conservatively kept (an active reproduce-the-
  crash session could re-run them).
- **KEPT (protected):** `/tmp/gitsign` (signing config), `/tmp/rxpool-wt` (live git
  worktree, RX agent). Also left the system `nix-*` build dirs and `systemd-private-*`.
- **No secrets found:** no `/tmp/creds.txt` or `*cred*`/`*secret*` scratch. The `.pem`
  files listed by ssh-add are ssh-agent-loaded keys, not deletable scratch.

### (c) LAN
- No other LAN hosts under our control. The only RUNNING osv-* box is the live
  fork-teardown debug agent's (`osv-teardbg`, see Task 11) - reported, NOT touched.

---

## Task 11 - AWS inventory (AWS_PROFILE=chiuso, us-east-2, READ-ONLY)

**Nothing created, terminated, or deleted.**

**RUNNING osv-* instances (1) - LEFT untouched:**
| id | type | name | launch | key | disposition |
|----|------|------|--------|-----|-------------|
| i-001e325892157787a | m5d.metal | **osv-teardbg** | 2026-08-27 04:40 | osv-rxval | **OURS, but a LIVE fork-teardown debug agent is using it** (matches TD-BOX.txt @ 18.118.166.170 + the minutes-old /tmp scratch + the open ssh_mux socket). Per the task rule, NOT touched - reported only. |

Other RUNNING instances (all other projects, left, not osv-*): flux-clean-bench
(c7i.4xlarge, flux), fts-zone-20260827-005656 (r6id.4xlarge, fts), solnix-arm64-kernel
+ solnix-desktop-gburd + solnix-aa-pgdeps (m5.4xlarge, solnix), a6hw-acpi-groundtruth
(c6g.medium, solnix/a6hw). None are osv-*.

**AVAILABLE (unattached) volumes tagged osv-*: 0.** (52 total available, all untagged
build-fleet scratch matching the solnix timeline; 51->52 since sweep #3.) Per the task
rule they are NOT osv-* so NOT our candidates. They are >2h old and accruing cost, but
attribution is ambiguous (untagged). **Flag for the solnix-fleet owner / human:** ~52
untagged available volumes accumulating in us-east-2. Deleted NOTHING.

**Self-owned AMIs named osv-* (or tagged osv-*): 0.** (23 total, ALL solnix-* by name;
0 with an osv-containing tag value - the ROADMAP's `osv-v7-forkfix` AMI is not present
under an osv name or tag, either never persisted with that tag or already deregistered.)
Left.

**Self snapshots described osv-* (or tagged osv-*): 0.** (35 total, ALL solnix-*
descriptions; 0 osv tags.) Left.

**Net:** 1 running osv-* box = a LIVE fork-teardown debug agent (not touched). 0 osv-*
volumes/AMIs/snapshots. 0 orphans of ours. Terminated/deleted nothing.

---

## SUMMARY

**PRs needing action / what I addressed:** Nothing was mechanically actionable.
Upstream/master is unchanged (`0e34e4dc2`), NO new reviewer/bot comment landed on any
of the 32 open PRs since sweep #3, and every prior finding is fixed-in-code (verified
at the #1439 inline-thread level), answered (#1461 design dialogue, awaiting nyh), or
superseded and re-filed as #1482. I posted no comments and pushed no code (posting
would be noise; maintainer offline til ~Nov).

**PRs opened/edited this pass:** NONE. Verified still-good: **#1483**
(pagecache-munmap-sync-nothrow, OPEN/MERGEABLE, single signed commit on master tip,
3-file focused diff, leak-clean), **#1482** (numa-harden, OPEN/MERGEABLE, 0 comments),
**#1424** (crucible, OPEN/MERGEABLE/not-draft), osv-apps
`wip/postgres18-musl-demo-synced` (0 behind cloudius/master, touches only
postgres18-musl/). #1478 + follow-ons (#1479/#1480/#1481) all clean/MERGEABLE.

**External-dep status:** OpenZFS latest stable = **2.4.4** (`71a9f9578`); master pins
2.4.3 (`83020cf8`), 1 behind - report-only, needs a validated patch rebase. musl 1.2.x
fork-rebase = backlog (fork tip advanced but bump is a deliberate rebase). kbuild pin ==
fork HEAD; acpica/musl-forks current. Crucible driver == upstream V13. No bumps done.

**Upstream-issue status:** lwext4 #100 (only external issue we filed) still OPEN, 0
comments, unchanged, dormant upstream, non-blocking. No openzfs/musl/Crucible issues
filed by us. Our tracker osv#1474 still OPEN. Nothing actionable.

**Plan remaining (categorized):**
- (a) blocked-on-maintainer: #1455 gate + fork stack (#1456/#1458/#1459/#1475) +
  M2/PGXN + ~19 clean PRs awaiting review (incl. #1464 APPROVED, #1483, #1482, #1424) +
  the elf segment-sharing fork-stack follow-on (f6b07f239, banked on wip/pg-zfs-bench-v8).
- (b) blocked-on-our-work: **the fork-teardown NULL-deref crash (the M1 HammerDB gate;
  a live osv-teardbg agent is on it)**; numa forward-port (#1438/#1441/#1445; hardening
  done as #1482); IPv6 forward-port (#1442/#1444); ext4-perf rebase (#1447); OpenZFS
  2.4.4 bump; KVM-metal ZFS validation of vn_access + native-zfs-fixes.
- (c) ready-to-do: force-push the 13 banked rebases when wanted; #1483/#1482/#1424
  review when the maintainer returns.

**Active blocker:** the fork resume-context / address-space TEARDOWN NULL-deref in
`destroy_address_space` (core/mmu.cc:767) when a forked PG backend that mmap'd a file
exits under HammerDB ANALYZE load. The teardown counterpart to v7's segment-sharing
fix; the AS0 reaper disposes a fork-shared (AS0-owned) vma as if private. Fork-stack
(#1455) territory; a live osv-teardbg debug box is on it.

**What I cleaned locally:** 15 dead-scratch files (~312MB, dominated by my own 312M
bash tool log; plus Aug 24-25 gdb/probe python + this-session rebase log). Left ALL
osv-teardbg live files (rungdb*/gdb*.cmds/runqemu/dobuild/sshosv/pgsync-body, 04:35-05:12
today) and the Aug 26 bake/HammerDB scratch a live debug agent may re-source. Kept
`/tmp/gitsign` + `/tmp/rxpool-wt`. No worktrees pruned (none dead). No tracked files /
`.local` notes / branches deleted. No force-push, no un-draft, no merge, no pin bump.

**AWS inventory:** 1 running osv-* box (osv-teardbg = our LIVE fork-teardown debug box,
NOT touched; other running boxes are solnix/flux/fts, all other projects). 0 osv-*
volumes/AMIs/snapshots. 52 untagged available volumes (not ours; flagged for the
solnix-fleet owner). Terminated/deleted nothing.

**This was a NO-OP verification round:** nothing moved upstream, nothing new became
actionable, so nothing was pushed or opened. All sweep #1/#2/#3 work verified intact.
The only mutation this pass was local /tmp dead-scratch cleanup.
