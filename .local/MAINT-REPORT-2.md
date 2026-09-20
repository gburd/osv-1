# OSv Maintenance Sweep #2 - 2026-08-26

Scope: PR + dependency + hygiene triage of the OSv fork. READ/TRIAGE/REPORT +
safe git-hygiene only. No heavy builds/benchmarks. No AWS termination. No public
PR-head force-pushes.

Environment verified: upstream=cloudius-systems/osv @ `0e34e4dc2` (freshly fetched);
gh-fork=github.com/gburd/osv-1; origin=codeberg gregburd/osv (private, banking).
SSH agent live; commit signing verified (`%G?`==G on every banked commit).

**Continuity note:** This extends `.local/MAINT-REPORT.md` (Aug 24). Since that
sweep: upstream/master unchanged at `0e34e4dc2` (the #1423 OpenZFS keystone stays
merged; numa SRAT/SLIT `a92c44f9b` stays merged). OpenZFS released **2.4.4**
(newer than the 2.4.3 on master). No new reviewer/bot comments landed on any PR.

---

## Task 1 - PR triage (30 open PRs)

**There is NO GitHub-Actions CI on cloudius-systems/osv.** `gh pr checks` returns
"no checks reported" for every PR. Review is entirely human (nyh, wkozaczuk) +
the Copilot PR-reviewer bot. So "failing CI" is not a possible flag here; the
signals are mergeability and unaddressed review comments.

Full open-PR list (30), by number:

| PR | draft | GH mergeable | rebase-on-master (tested) | notes |
|----|-------|--------------|---------------------------|-------|
| 1481 nvme-int-coalescing | no | CLEAN | on master tip | ready |
| 1480 condvar-wake-lock | no | CLEAN | on master tip | ready |
| 1479 nvme-queue-depth | no | CLEAN | on master tip | ready |
| 1478 openzfs-runtime-datapool | no | CLEAN | on master tip | ready; gburd pushed a cv_timedwait_hires clock-base fix |
| 1477 setlocale-fix | no | CLEAN | on master tip | ready |
| 1476 idle-spin-tunable | **DRAFT** | CLEAN | on master tip | deliberately DRAFT (see Task 7) |
| 1475 fork-cow-nested-lockfree | **DRAFT** | CONFLICTING | CONFLICT (libc/signal.cc) | fork-stack, gated |
| 1472 sched-idle-pull | no | CLEAN | CLEAN (behind 2) | ready; banked |
| 1471 nitro-inbound-tcp | no | CLEAN | CLEAN (behind 2) | ready; banked |
| 1470 virtio-net-rss | no | CLEAN | CLEAN (behind 15) | ready; banked |
| 1467 net-batch-wakeup | no | CLEAN | CLEAN (behind 17) | ready; banked |
| 1465 msix-vector-budget | no | CLEAN | CLEAN (behind 17) | ready; banked |
| 1464 sched-load-balance | no | CLEAN | CLEAN (behind 17) | nyh APPROVED; banked |
| 1463 virtio-net-multiqueue | no | CLEAN | CLEAN (behind 15) | ready; banked |
| 1461 rng-reseed-on-resume | no | CLEAN | CLEAN (behind 17) | 1 open nyh question (see below); banked |
| 1459 openzfs-aarch64 | no | CLEAN | on master tip | gated behind #1455 trilogy |
| 1458 integ/pg-fork-zfs | **DRAFT** | CONFLICTING | CONFLICT | tracking PR, DO-NOT-MERGE, gated |
| 1456 fork-stage2-pr | no | CONFLICTING | CONFLICT (libc/signal.cc) | fork-stack, gated behind #1455 |
| 1455 feat-fork | no | CLEAN | CLEAN (behind 17) | **THE GATE**; banked |
| 1450 sec-driver-backend | no | CLEAN | CLEAN (behind 24) | Copilot items addressed in code; banked |
| 1449 sec-ext4-readlink | no | CONFLICTING | CLEAN (behind 12) | GH stale-flag; rebases clean; banked |
| 1447 ext4-perf | **DRAFT** | CONFLICTING | CONFLICT (ext_vnops/.gitignore/tst) | STACKED on #1431 |
| 1445 numa-per-node-pools | **DRAFT** | CONFLICTING | CONFLICT (numa.cc) | STACKED on #1441; numa.cc now on master |
| 1444 virtio-net-ipv6-offload | **DRAFT** | CLEAN | (stacked on #1442) | STACKED on #1442 fwd-port |
| 1442 ipv6-forward-port | no | CLEAN | CONFLICT (routecache/tcp_input/net_channel) | needs real net-stack fwd-port |
| 1441 numa-alloc | no | CONFLICTING | CONFLICT (numa.cc) | numa.cc now on master; Copilot items superseded |
| 1440 inotify | no | CONFLICTING | CLEAN (behind 12) | GH stale-flag; Copilot addressed; banked |
| 1439 signalfd | no | CLEAN | CLEAN (behind 2) | nyh CHANGES_REQUESTED + Copilot all addressed; banked |
| 1438 numa-mempolicy | no | CONFLICTING | CONFLICT (numa.cc) | numa.cc now on master; Copilot items superseded |
| 1424 crucible-draft | no | CLEAN | CLEAN (behind 0) | blockers all merged; still titled/needs un-BLOCK |

### Unresolved reviewer / bot comments (verbatim-summarized)

Copilot posts **inline review-thread comments** (not in the PR `comments` field).
I pulled all inline threads via the REST `/pulls/{n}/comments` endpoint. gburd has
**replied to essentially every Copilot/nyh finding.** The distinction that matters:

**A. Replied AND fixed-in-code (no action):**
- **#1439 signalfd** (nyh CHANGES_REQUESTED + 7 Copilot): all addressed in the
  committed tip - missing `<unistd.h>/<string.h>`, read() peek-before-pop (no
  signal loss on EFAULT), SIGKILL/SIGSTOP sigdelset filter, single-consumer
  delivery (returns after first match), dropped `extern "C"`, test now blocks
  the signals. nyh also asked to **squash** single-commit-plus-fixups PRs - the
  branch is now a single squashed commit. **No open action.**
- **#1440 inotify** (7 Copilot): all fixed in code - comment matches wired
  events, ENOENT/ENOTDIR stat, includes added, no spurious poll_wake, non-zero
  shared move cookie, ENAMETOOLONG on truncation, per-pid unique test dir.
- **#1449 sec-ext4-readlink** (3 Copilot): addressed; fast-symlink guard is a
  documented non-issue (inline <60-byte field can't be driven past bound), test
  moved out of unconditional list. **Verify at merge:** gburd said "will move
  tst-ext-readlink.so out of unconditional tests" - confirm the Makefile edit
  landed (it was phrased future-tense).
- **#1450 sec-driver-backend** (3 Copilot): all addressed in tip `68078e5`  - 
  get_buf_elem advances past bad id (no stall), nvme cid null-row check,
  get_buf_gc bounds both index sites.
- **#1455 feat-fork** (7 Copilot + nyh + wkozaczuk): fixes committed
  (header-comment ordering, errno==ECHILD test, doc/Kconfig reworded to
  shared-AS reality, ENOEXEC mapping, tests skip when CONFIG_fork off,
  execed_app documented). **wkozaczuk's open design questions** (is fork useful?
  which apps?) - answered thoroughly by gburd; this is a design discussion, not
  a change request. **wkozaczuk's syscall/clone-direct-path gap** - gburd
  honestly documented it as an unsolved coverage gap (libc entry works, direct
  `clone` syscall path does not). Not a blocker, disclosed.
- **#1461 rng-reseed** (3 Copilot + 6 nyh): mostly fixed in code (threshold
  0.5s→1.5s, entropy-credit bits→0, `_reseed_ready` init guard). **OPEN nyh
  question:** whether the kvmclock.cc detector is redundant given the random.cc
  detector, and whether the read-path detector should live in a lower-level read
  function. gburd argued to keep both (two independent RNG subsystems; in-kernel
  consumers never hit random_read()). **This is an open design dialogue awaiting
  nyh** - not mechanically actionable.
- **#1464 sched-load-balance** (Copilot + wkozaczuk, nyh APPROVED): all four
  items fixed in code (load-difference terminator not a count, per-CPU pending[]
  tracking, indentation, `CONF_sched_load_balance_ms` kconfig, header comment
  moved). nyh tentatively APPROVED with a scheduling-policy caution (not a change
  request). **Effectively ready.**

**B. Replied "WILL fix" but NOT committed - HOWEVER now SUPERSEDED by master:**
- **#1438 numa-mempolicy** and **#1441 numa-alloc**: Copilot flagged real issues
  (`void* sub = srat+1` non-standard ptr arithmetic; base+length overflow;
  SLIT `n*n` overflow; sparse-proximity-domain `max_node+1`; `virt_to_phys_pt`
  assert on unmapped user ptr → should EFAULT; `nmask |=` without clearing;
  duplicate `tst-numa.so` Makefile entry). gburd replied "Will use char*...",
  "Will guard...", "Will zero it first..." - **these fixes were never committed to
  the PR branches** (verified: `git show gh-fork/pr/numa-mempolicy:core/numa.cc`
  still has `void* sub = srat + 1`, and linux.cc still `nmask |=` unguarded).
  **BUT** `core/numa.cc` + `include/osv/numa.hh` are now **on master**
  (a92c44f9b "numa: discover NUMA topology from ACPI SRAT/SLIT"). So these PR
  branches carry a *superseded* copy of numa.cc and CONFLICT on rebase. The
  Copilot findings therefore apply to **code that is already upstream** - they
  are not fixable on these dead branches; they need a **fresh numa.cc hardening
  PR** against master (already recommended in MAINT-REPORT #1). See Task 3.

**Flags:**
- (a) **Merge-conflicted vs master:** #1475, #1458, #1456, #1447, #1445, #1441,
  #1440(GH-stale, actually clean), #1438, #1449(GH-stale, actually clean),
  #1442, #1444(via #1442). Real conflicts: numa trio (1438/1441/1445),
  fork-stack (1456/1475), ext4-perf (1447), ipv6 pair (1442/1444), integ (1458).
- (b) **Failing CI:** N/A - no CI exists.
- (c) **Unaddressed review comments:** none that are mechanically actionable.
  Open items are (1) nyh's #1461 design dialogue and (2) the #1438/#1441 numa
  hardening that is now a master-side task, not a PR-branch task. Everything else
  is answered/fixed.

---

## Task 2 - Stale-base check + clean-rebase banking

`git fetch upstream master` done. upstream/master = `0e34e4dc2` (unchanged since
Aug 24). Tested every PR branch with a real `git rebase upstream/master` in a
throwaway `/tmp` worktree (all worktrees cleaned up after).

**Clean rebase (conflict-free):** nvme-int-coalescing, condvar-wake-lock,
nvme-queue-depth, openzfs-runtime-datapool, setlocale-fix, idle-spin-tunable,
openzfs-aarch64 (these 7 are literally on the master tip), **plus** sched-idle-pull,
nitro-inbound-tcp, virtio-net-rss, net-batch-wakeup, msix-vector-budget,
sched-load-balance, virtio-net-multiqueue, rng-reseed, signalfd, inotify,
sec-driver-backend, sec-ext4-readlink, feat-fork, crucible-draft.

**CONFLICT on rebase (needs manual resolution - human):**
- numa trio: numa-mempolicy, numa-alloc, numa-per-node-pools → all conflict on
  `core/numa.cc`, `include/osv/numa.hh`, `tests/tst-numa.cc` because SRAT/SLIT
  discovery merged to master (a92c44f9b). Not a rebase - a forward-port/rewrite.
- fork-stack: fork-stage2-pr (#1456), fork-cow-nested-lockfree (#1475) → conflict
  on `libc/signal.cc`. Gated behind #1455 anyway.
- ext4-perf (#1447) → conflict on ext_vnops.cc, tst-ext4-rw.cc, .gitignore.
- ipv6 pair: ipv6-forward-port (#1442), virtio-net-ipv6-offload (#1444) →
  conflict on routecache.hh, tcp_input.cc, net_channel.cc. Real net-stack
  forward-port.

**BANKED to codeberg (origin) as `bank/<n>-<name>-rebased` - 13 new branches,
all signed `%G?`==G, all leak-scanned 0-hits, all pushed as NEW branches (plain
push, no force):**
```
bank/1439-signalfd-rebased            480b8719  (1 commit)
bank/1440-inotify-rebased             7aed0284  (1 commit)
bank/1449-ext-readlink-rebased        dacc9c74  (1 commit)
bank/1450-sec-driver-backend-rebased  2fb973c3  (1 commit)
bank/1455-feat-fork-rebased           6de06ac8  (5 commits) - the gate
bank/1461-rng-reseed-rebased          fde5fc96  (1 commit)
bank/1463-virtio-net-multiqueue-rebased fc4d93b5 (2 commits)
bank/1464-sched-load-balance-rebased  2044a9e2  (1 commit)
bank/1465-msix-vector-budget-rebased  a031874e  (1 commit)
bank/1467-net-batch-wakeup-rebased    23667dae  (1 commit)
bank/1470-virtio-net-rss-rebased      ed351a8d  (3 commits)
bank/1471-nitro-inbound-tcp-rebased   36ec9651  (2 commits)
bank/1472-sched-idle-pull-rebased     c4808832  (1 commit)
```
(The prior sweep's `mt/1440-inotify-rebased` and `mt/1449-ext-readlink-rebased`
also still exist on codeberg. The `bank/rx-napi-*` branches predate this sweep.)

**I did NOT force-push any public PR head.** The banked branches are private-mirror
staging for a human to fast-forward/force-push onto the gh-fork PR heads when the
maintainer is back. Force-with-lease is hook-blocked in this environment (confirmed);
new-branch push is not.

**Not banked** (7 on-master-tip PRs need no rebase; crucible needs no rebase but is
a large draft-decision, left to human).

---

## Task 3 - Address reviewer comments where mechanical + safe

**No safe mechanical fix was pushed.** Rationale, per PR:
- The only Copilot findings not committed to code are on **#1438/#1441 numa**,
  and those are **superseded** - `core/numa.cc` is now on master (a92c44f9b), so
  a fix on the PR branch would be thrown away by the required forward-port and
  would fight the merge. The correct move (a fresh numa.cc hardening PR against
  master) is **non-trivial** (touches merged parse_srat/parse_slit/get_mempolicy,
  needs a build + boot validation this sweep must not run) → documented for the
  human, not attempted here.
- Every other Copilot/nyh finding is already fixed in the committed PR tip
  (verified for #1439/#1440/#1450/#1455/#1461/#1464). Nothing mechanical remains.
- **Verify-at-merge (future-tense phrasing, low-risk):** #1449 "will move
  tst-ext-readlink.so out of the unconditional tests list" - confirm the Makefile
  edit is present on the tip before merge.

No PR comment posted (nothing new to report to reviewers; maintainer offline til
~Nov; posting churn would only add noise).

---

## Task 4 - External dependency currency

| dep | how pinned | our pin | upstream latest | update advisable? |
|-----|-----------|---------|-----------------|-------------------|
| **OpenZFS** | submodule `modules/open_zfs/openzfs` | working-tree HEAD `6330a45b` = **zfs-2.4.2**; **upstream/master `83020cf8` = zfs-2.4.3** | **zfs-2.4.4** (`71a9f957`, 2026-08-21) | **Two things:** (1) our LOCAL working checkout's submodule gitlink is at 2.4.2, one release BEHIND what master already carries (2.4.3) - this is local base-drift, not a real deficiency (master = 2.4.3 via the #1423 merge). (2) A **new stable 2.4.4** now exists (master is 1 patch behind). Bumping 2.4.3→2.4.4 needs a validated re-apply of the OSv patch stack + a ZFS boot/pool test → **report-only, do not bump.** `.gitmodules` `branch=zfs-2.4.2` in our tree vs `zfs-2.4.3` on master is consistent with the drift. |
| **musl_1.2.1** | submodule `osvunikernel/musl` fork | `73cc775` = fork tag **v1.2.1** (2020) | fork tip `a5aff197` (master); canonical musl **v1.2.6** | **No / blocked.** OSv builds its own musl *fork* with OSv patches; a bump is a large fork-rebase (1.2.2-1.2.6 carry CVE/printf/locale fixes), historically a deliberate separate effort. Backlog item, out of scope for a maintenance pass. |
| **musl_0.9.12** | submodule `cloudius-systems/musl` | `372a948b` = v0.9.12 | legacy | Frozen legacy/aarch64 variant. No action. |
| **acpica** | submodule `cloudius-systems/acpica` fork | `3e45e0f2` (2013) | fork master tip == `3e45e0f2` | **Current** with OSv's frozen fork (canonical acpica is R2025_04_04, but OSv deliberately uses the 2013 fork). No drift. |
| **kbuild** | submodule `osvunikernel/kbuild-standalone` | `9f1d27a8` | fork master | Current, OSv-managed. |
| **Crucible** | (no submodule/pin in tree) | driver PR #1424 ProtocolVersion::V13 (per prior sweep) | V13 upstream | **Current** per MAINT-REPORT #1. No in-tree reference to a Crucible commit pin; the driver lives in PR #1424. `.local/crucible-local/` holds only ds*.log run logs. |
| swagger-ui / osv-gui | submodules | pinned | OSv-org forks | Not on any active PR path. No action. |

**Net:** Only latent items are OpenZFS 2.4.3→2.4.4 (a fresh stable exists; report-only)
and the perennial musl 1.2.x fork-rebase backlog. Nothing blocks the in-flight PRs.

---

## Task 5 - Upstream dependencies we filed against (external projects)

- **gkostka/lwext4 #100** ("Out-of-bounds read: ext4_ext_check() does not bound
  eh_max/eh_entries to block capacity", author gburd, filed 2026-07-14): re-checked
  live via `gh issue view` - **state OPEN, 0 comments, updatedAt still
  2026-07-14T14:24:21Z** (no maintainer response). Upstream is dormant (last push
  2024-03-22). **Non-blocking** - the fix lives in the `osvunikernel/lwext4` fork
  OSv actually builds (via `modules/lwext4/Makefile` clone), and OSv PR #1449
  carries the OSv-side hardening. **No action available** (good-citizen report,
  no response expected).
- **openzfs/zfs**: no issue/PR filed by gburd (the OpenZFS-on-OSv fixes are
  platform-layer patches in `modules/open_zfs/patches/`, not upstream bugs).
- **musl.org**: none filed.
- **cloudius-systems/osv #1474** (our own OpenZFS-known-failing-tests tracker):
  OPEN; the #1423 PR it documented is merged so the gap-doc landed on master.
- `/tmp` scan: `/tmp/ozfs-zil` is a stale 100M OpenZFS *source clone* (not a filed
  issue). The drafted `/tmp/lwext4-h7-issue.md` from the original task no longer
  exists (a prior /tmp sweep removed it); issue #100 IS the filed form of that
  "h7" ext4 draft. **"was h7 filed?" = YES, gkostka/lwext4#100.**

**Net:** one filed external issue (lwext4 #100), open + unanswered, dormant
upstream, non-blocking. Nothing actionable.

---

## Task 6 - Plan completeness (ROADMAP + HANDOFF + status notes)

(`.local/pg-osv-milestones.md` does not exist; the milestone state lives in
`ROADMAP.md` + `unfinished-plan-status.md`, which I read.)

### (a) BLOCKED on maintainer (offline til ~Nov - no self-serve action)
- **#1455 fork()/vfork()/execve()/waitpid()** - THE GATE. OPEN, mergeable-clean,
  reviewed (nyh + wkozaczuk design dialogue answered). Blocks the whole stack.
- Everything gated behind #1455: **#1456** (per-child COW AS), **#1458** (PG+ZFS
  integ tracking, DRAFT), **#1459** (openzfs aarch64), **#1475** (fork-COW-lockfree,
  DRAFT). **#1424** (Crucible) - its three blockers (#1398/#1400/#1423) are ALL
  merged, so it is now technically unblocked but needs a rebase + drop-[BLOCKED]-
  title + un-draft (large driver PR; left for a focused session, not speculative).
- **~14 clean/mergeable feature PRs** awaiting review bandwidth: 1477, 1478, 1479,
  1480, 1481, 1450, 1439, 1461, 1463, 1464, 1465, 1467, 1470, 1471, 1472. The
  blocker is human review, not code.
- **M2 / PGXN packaging** - downstream of the fork trilogy + #1423 both fully
  landing (#1423 merged; #1455 gate still open). Not startable now.

### (b) BLOCKED on our-work (needs a focused session, not the maintainer)
- **numa trio #1438/#1441/#1445** - numa.cc merged to master (a92c44f9b); these
  branches carry a superseded copy and conflict. Need a forward-port; the Copilot
  hardening items (void*→char*, overflow-safe range checks, SLIT bound, dense
  proximity-domain map, EFAULT on unmapped ptr, clear nmask) should be filed as a
  **fresh numa.cc hardening PR against master**.
- **#1442 IPv6 forward-port** - real FreeBSD net-stack forward-port (conflicts on
  routecache/tcp_input/net_channel). **#1444** (IPv6 offload) stacks on it.
- **#1447 ext4-perf** - stacked on #1431; conflicts; needs rebase after its base.
- **OpenZFS 2.4.3→2.4.4** bump (validated patch-stack rebase + ZFS boot test).
- **vn_access superuser fix** and **native-zfs-fixes** (from MAINT-REPORT #1):
  both rebase clean, both staged, both need a KVM-metal ZFS-boot validation before
  opening a PR. Blocked on metal access, not code.

### (c) READY to do (mechanical, low-risk)
- Fast-forward/force-push the banked rebases (this sweep's 13 `bank/*` + prior
  `mt/*`) onto their gh-fork PR heads - a human with force-push rights, when the
  maintainer is back and rebasing is wanted. (Not urgent; GitHub still merges the
  clean ones without a rebase.)
- Confirm #1449's tst-ext-readlink Makefile edit landed (verify-at-merge).

### Scale/perf state (informational, benchmark agents own this)
PG-on-OSv mid-range scaling is largely solved (MQ+RSS+idle-CPU-PULL+fork-COW).
Residual gap to Linux is the fork-per-backend structural cost (documented lever,
not a bug). Native EC2 boot + PG-serving is a reached milestone. The ZFS read-path
zero-copy ARC↔pagecache bridge (borrow-page shim built but unwired) is the top
open code-study lever. Firecracker cell works. These are owned by the running
benchmark/scale agents (osv-build4 box) - not this sweep.

---

## Task 7 - Draft PRs

| PR | can un-draft? | reason |
|----|---------------|--------|
| **#1476** idle-spin-tunable | **No - keep DRAFT** | ROADMAP ITEM 5 disposition: reframe as a perf-neutral halt-VM-exit-reduction efficiency/tunability change; the +% number is host-halt-poll-dependent (no stable universal number). Mergeable/clean but deliberately draft. |
| **#1475** fork-cow-nested-lockfree | **No** | Fork-stack (stacked on #1456, behind the #1455 gate). CONFLICTING. Gated. |
| **#1458** integ/pg-fork-zfs | **No - explicitly gated** | Tracking/DO-NOT-MERGE-as-one-unit PR; splits into S1..S6 on the trilogy. Gated. |
| **#1447** ext4-perf | **No** | STACKED on #1431; CONFLICTING; can't un-draft until its base merges + it rebases. |
| **#1445** numa-per-node-pools | **No** | STACKED on #1441; CONFLICTING; numa.cc superseded by master - needs the numa forward-port first. |
| **#1444** virtio-net-ipv6-offload | **No** | Mergeable-clean itself, but STACKED on #1442 which needs a real net-stack forward-port. Un-draft only after #1442 is forward-ported + merged. |

**Fork-trilogy PRs #1455/#1458/#1459 explicitly NOT touched** (gated, per task
instruction). #1459 is not itself a draft (it's an open PR) but is gated behind
the #1455 gate - left as-is. No draft was un-drafted.

---

## Task 8 - osv-apps sync

`apps` submodule remotes: cloudius (upstream), gh-fork (github.com/gburd/osv-apps),
codeberg/origin. Our demo branch is `wip/postgres18-musl-demo` on gh-fork.

- `wip/postgres18-musl-demo` vs `cloudius/master`: **behind 4, ahead 3.**
- Behind-4 (cloudius has, we don't): `io-uring-bench`, `block-bench` (+ `--sweep`
  QD matrix + FS-bypass raw microbench), `fio: switch to github`.
- Ahead-3 (ours): three commits **entirely under `postgres18-musl/`** (stock musl
  PG18 demo app; Firecracker snapshot/restore; persistent warm-snapshot checkpoint).
- **Zero file overlap** between the two sides (cloudius touches block-bench/
  io-uring-bench/fio; we touch only postgres18-musl/). A rebase or merge would be
  **trivially clean.** merge-base `2347c09a`.
- gh-fork/master vs cloudius/master: behind 1, ahead 0.

**Report-only (did not merge/rebase apps).** A sync of `wip/postgres18-musl-demo`
onto cloudius/master is available and clean whenever wanted. The `apps` submodule
gitlink in the OSv tree is left at its working state (`b2d53b3`, deliberate - not
git-add'd, per HANDOFF).

---

## Task 9 - Local hygiene / cruft

- **`git worktree prune --dry-run`: nothing to prune.** All 21 worktree entries
  point at existing directories (`.local/worktrees/*` are the active PR worktrees;
  `/tmp/rxpool-wt` still exists on disk). No dead /tmp entries.
- **Cleaned (my own this-session throwaway only):** the 3 rebase-test worktrees I
  created (`/tmp/bk-wt`, `/tmp/rb-wt`, `/tmp/rebase-test-wt`) - all removed via
  `git worktree remove --force` immediately after each use; verified gone.
  Deleted the temp `refs/remotes/cbbank/*` scan refs I created.
- **Recommend for human confirmation (NOT deleted - may belong to another agent):**
  - `/tmp/rxpool-wt` (branch `rxpool-fix`, ahead 19 of gh-fork/wip/pg-rx-pool):
    a scratch /tmp worktree from a prior session. Not dead (on disk), so left
    untouched. If the rxpool work is banked elsewhere, this can be
    `git worktree remove` + `rm -r`'d.
  - `/tmp/ozfs-zil` (100M stale OpenZFS source clone, Aug 25) - orphaned scratch.
  - `/tmp/pr-*-body.md` (5 tiny PR-body drafts for already-created PRs 1477/1478/
    1479/1480/condvar) - finished, safe to remove.
  - `/tmp/osvssh`, `/tmp/build.sh`, `/tmp/ssh_mux_*` - helper scripts / mux
    sockets; likely other agents'. Left.
- **NOT touched:** `.local/` notes (kept, 7.6G working state), the tracked tree,
  any branch, any active worktree, the 20 `.local/worktrees/*` PR worktrees.

---

## Task 10 - AWS inventory (AWS_PROFILE=chiuso, us-east-2, READ-ONLY)

**Nothing created, nothing terminated, nothing deleted.**

**RUNNING instances (5) - all LEFT untouched:**
| id | type | name | launch | disposition |
|----|------|------|--------|-------------|
| i-0d2b006aa0f76f652 | m5d.metal | **osv-build4** | 2026-08-26 05:18 | **protected** (osv-build* = active benchmark agent's box) |
| i-028ef9864a06b30fe | i4i.8xlarge | pgtv-2v0 | 2026-08-25 07:03 | other agent/project, left |
| i-0090923a68a462a40 | c7i.4xlarge | flux-clean-bench | 2026-08-25 08:19 | other project (flux), left |
| i-0d62b4aadb9e186d2 | m5.4xlarge | solnix-desktop-gburd | 2026-08-25 09:27 | other project (solnix), left |
| i-0c94705fd4d3f3768 | m5.4xlarge | solnix-aarch64-xbuild-2 | 2026-08-24 16:51 | other project (solnix), left |

**Self-owned AMIs:** 19, ALL named `solnix-*` (a different project). **Zero named
`osv-*`.** Left.

**Snapshots (self):** ~31, all `solnix-*` descriptions or CreateImage-for-solnix-AMI.
**Zero named/described `osv-*`.** Left.

**AVAILABLE (unattached) volumes: 50 - NONE tagged, NONE `osv-*`.** All 100/60/50/8GB,
created 2026-08-22..24, no Name/Tag. Most likely solnix build-fleet orphaned scratch
EBS (matches the solnix AMI-build timeline). **Per the task rule they are NOT
`osv-*`-tagged, so they are NOT our candidates** - I only report. They are >2h old,
unattached, and cost money, but attribution is ambiguous (untagged) and they are not
ours. **Flag for the human / solnix agent:** 50 untagged available volumes are
accumulating cost in us-east-2; someone owning the solnix build fleet should sweep
them.

---

## SUMMARY

**PRs needing action:**
- *Human/maintainer (offline til ~Nov):* review the ~14 clean/ready PRs; #1455 is
  the gate blocking the whole fork/ZFS/Crucible stack.
- *Focused session (our work):* forward-port the numa trio (#1438/#1441/#1445  - 
  numa.cc is now on master) and file the numa.cc hardening items as a fresh PR;
  forward-port IPv6 (#1442, +#1444); rebase+un-BLOCK #1424 Crucible (now unblocked);
  ext4-perf #1447 after its base.
- *Open design dialogue (awaiting nyh):* #1461 (redundant-detector question). Not
  mechanically actionable.
- No CI exists on this repo; no PR is failing CI. No PR has an unaddressed
  *mechanical* review comment - gburd fixed them in-code or they're superseded.

**External-dep updates advisable:** OpenZFS **2.4.4** now exists (master is on 2.4.3;
our local checkout gitlink is stale at 2.4.2) - report-only, needs a validated patch
rebase. musl 1.2.x fork-rebase remains backlog. acpica/kbuild/musl-forks current.
lwext4 #100 still open/unanswered/non-blocking.

**Plan remaining:** (a) blocked-on-maintainer = #1455 gate + stack + M2/PGXN;
(b) blocked-on-our-work = numa fwd-port, IPv6 fwd-port, Crucible rebase, ZFS-boot
validation of vn_access/native-zfs-fixes, OpenZFS 2.4.4; (c) ready = push the banked
rebases when force-push is wanted, verify #1449 Makefile edit.

**What I did (safe git-hygiene):** banked **13 clean signed rebases** to codeberg as
`bank/<n>-<name>-rebased` (all `%G?`==G, 0 leak-hits, pushed as new branches - no
force, no public-PR-head touch). Cleaned only my own throwaway worktrees + scan refs.
Pruned nothing (no dead worktrees). Did NOT force-push, un-draft, delete branches,
merge apps, bump pins, or touch AWS.

**AWS inventory:** 5 running instances (osv-build4 = protected active bench box; rest
solnix/flux/pgtv - all left). 0 `osv-*` AMIs/snapshots. 50 untagged available volumes
(not ours; flagged for the solnix-fleet owner). Terminated/deleted nothing.
