# OSv upstreaming maintenance/tidy sweep - 2026-09-20

Follow-on to `.local/maint-2026-09-19-sweep.md`. Everything re-verified TODAY (2026-09-20 14:48-15:40 UTC).
Read-heavy. Changes made: fetches, the task-9 notes commit + push to both mirrors, two draft reply files.
Nothing posted to any PR, nothing rebased, nothing force-pushed, no dependency bumped, no box touched.

DID NOT TOUCH (per brief): LIVE EC2 `i-0f6bc380d2ff4c4d9` + `i-031500bbc802fdadb` (Owner=agent-iouring,
both launched 14:06:4xZ today, the io_uring write-completion root-cause run) - no ssh, no terminate, no tag
change, EC2 section is REPORT-ONLY. Branches/files `bank/iouring-completion-fix`,
`bank/fork-footprint-reduction*`, `bank/fork-arena-real-reclaim`, `bank/fork-fd-reap-leak*`,
`bench/leakhunt`, `core/io_uring.cc`, `core/fork_arena.cc`, `core/sched.cc`, `core/pagecache.cc`,
PRs #1458/#1511/#1512, `.local/{iouring,scale,footprint2,cwwake,gates,leak2}/*`. The main worktree's 118
dirty paths were left exactly as found (verified after my commit: 98 untracked + 19 modified + 1 deleted,
0 staged by me).

Environment: SSH agent `/run/user/1000/wezterm/agent.3913155`. AWS profile `hotdog` (585335547908);
default/`lava` credentials are dead, so `AWS_PROFILE=hotdog` is required for any EC2 query.

=======================================================================
## HEADLINE - THE MAINTAINER IS BACK, MID-REVIEW, AND ASKED US A DIRECT QUESTION
=======================================================================

**@nyh broke 34 days of silence DURING this sweep** and reviewed two PRs in 16 minutes, both
**CHANGES_REQUESTED**:

| PR | review id | submitted | state | substance |
|----|-----------|-----------|-------|-----------|
| #1502 vfs dentry AB-BA | 5260826718 | 15:02:07Z | CHANGES_REQUESTED | 3 inline nitpicks + a long body critique; "the bug is real and the fix is correct" but 3 justifying claims are wrong/overstated, 2 of them in committed history; found a NEW worse latent bug; **asks us directly what the field use case was** |
| #1508 physio per-iovec | 5260899871 | 15:18:30Z | CHANGES_REQUESTED | 3 inline + body; questions whether `physio()` should exist at all; our #1424 justification for it is STALE by our own commit; we introduced an OOB read |

He states he "asked my AI to critically review it" on both and quotes it, with his own remarks bracketed.
Drafts written, **nothing posted** - both need your decisions, and #1502 asks a question only you can answer.

**METHODOLOGY FIX, BANK THIS IN THE STANDING SWEEP METHOD:** when I first scanned at 14:48Z the review was
PENDING/unsubmitted. In that state the three comments were **invisible** to
`pulls/<n>/comments`, `pulls/<n>/reviews`, GraphQL `reviewThreads`, the issue timeline, and notifications -
`pulls/comments/<id>` returned **404** and `pulls/1502/comments` returned `[]`. They were visible ONLY via
`repos/cloudius-systems/osv/events` and `users/nyh/events/public`. **The standard comment scan returns a
FALSE NULL while a review is in progress.** Always also check the events API for
`PullRequestReviewCommentEvent`. Today that was the difference between "0 new reviewer activity" (what the
normal scan said, and what I would have reported) and the most important finding of the sweep.

Other deltas vs the 2026-09-19 sweep:
- upstream/master **STILL 0e34e4dc2** (unmoved 34 days). Local master, origin/master, gh-fork/master all
  identical to it. No rebase needed anywhere.
- **#1511 and #1512 still have 0 comments / 0 reviews / 0 inline.** He reviewed #1502 and #1508, not these.
- **#1458's two comments (5718101962 S1..S8, and 5749965679) still have NO reply and 0 reactions.** The
  keystone composition decision is still unanswered, so the three validated fork fixes stay blocked.
- Two local branches already contain the exact reworks he asked for, written ~11:16-11:22 EDT today, before
  the review landed: `pr/vfs-dentry-lock-order-v2` (`d6166ed3a`, the `owned()` rework) and
  `pr/physio-per-iovec-v2` (`1b9b5add8`, physio -> `bdev_strategy_rw` wrapper). Both G-signed, merge-clean.
- **GitHub's CONFLICTING flag is stale on 2 PRs**: #1449 and #1440 now merge CLEAN via merge-tree.
- Task 9 done: notes refreshed and pushed to both mirrors, `1398cc43e` -> `5972d9241`.

=======================================================================
## TASK 1 - Reviewer comments on all 57 open gburd PRs
=======================================================================

Scanned all 57 open PRs four ways (issue comments, inline comments, reviews, AND the events API), filtering
gburd + bots. Then re-scanned after the review was submitted.

### FINDING: 2 NEW REVIEWS, both CHANGES_REQUESTED, both from @nyh, both today. First human activity in 34 days.

Before today the newest non-gburd non-bot event repo-wide was 2026-08-03 (25 historical human events).
@wkozaczuk remains silent - zero events on `cloudius-systems/osv` in his public feed.

### #1502 - @nyh, CHANGES_REQUESTED (the big one)

Three inline nitpicks on `fs/vfs/vfs_dentry.cc`:
- `4057182904` (14:32) duplicate `extern` decl - "harmless, but also useless."
- `4057202371` (14:42) "why is these extra depth variables needed? Don't our locks already have a depth?"
- `4057206258` (14:44) "can't we fix WITH_LOCK(dentry_hash_lock) to do those enter()/exit()?"

**All three are already fixed** by `d6166ed3a` on `pr/vfs-dentry-lock-order-v2` (written 11:22 EDT, before
the review): the `__thread` counter, both helpers, the `#else` stubs, the duplicate decl and every paired
call site are gone, and `vfs_dentry_hash_lock_held()` is `return dentry_hash_lock.owned();`. That also
answers comment 3 better than his suggestion - with `owned()` there is no hook to add to `WITH_LOCK`.

The review BODY is the substantive part. He opens "In general, the fix looked good to me, but I feel really
'rusty' in this code, so I asked my AI to critically review it. It agreed that the deadlock you found is
real, but had a bunch of complaints about the details." Quoting the key lines:

> **The bug is real and the fix is correct**. But three of the claims the PR uses to justify it are wrong or
> overstated, including one in a commit message and one in the test's header comment, and those should be
> corrected before this goes into history. There's also a worse latent bug sitting right next to the one
> commit 2 fixes.

> **Claim 1 that's wrong** - the reachability argument (commit 1 message): "It is reachable whenever the
> dentry being released is a directory, which namei() itself does on every path component, so it is not
> theoretical." That doesn't follow [...] namei() holds a dref on ddp while it holds vn_lock(ddp->d_vnode),
> so a concurrent drele() on that dentry cannot reach 0. And two threads walking the same path get the same
> dentry from dentry_lookup(). **You need two distinct dentries aliasing one vnode**, which the commit
> message never says.

> [Nadav: however, you said you saw this bug in practice, what use case did it use?]

> sys_rename() holds vn_lock(vp1) - the renamed object's own vnode, any type - from vfs_syscalls.cc:730 all
> the way across lookup(dest,...) at :746 [...] and dentry_move()/dentry_remove() at :827-829 [...] So the
> A-side of the cycle is not restricted to directory vnodes at all. [...] thread A does rename("/a", "/c"),
> thread B does the last close() of /b, where /a and /b are links to the same file. [...] On ramfs this
> particular recipe is unavailable (ramfs_link is vop_eperm) - but ZFS supports it, and the forking-server
> report was presumably not on ramfs.

> **Claim 2 that's wrong - the test (commit 3)** [...] "On an unfixed kernel this wedges with nothing
> runnable and the harness kills it by timeout." The PR description says the opposite, in bold: "The
> included stress test passes on unfixed code." [...] Both of these comments can't be true at the same
> time. [Nadav: Moreover, if this test really does **not** reproduce this bug, maybe it demonstrates my
> AI's claims that the scenario where you thought the hang could occur is incorrect - a hang can't occur
> then]. Also, how long does this new test run?

> **Claim 3 that's overstated** - "leaf lock" / "every acquisition routed through accessors" [...]
> dentry_hash_lock is not a leaf lock: vfs_dentry.cc:155-157 still takes dp->d_lock inside it via
> dentry_children_remove(). [...] dentry_move() still uses WITH_LOCK(dentry_hash_lock) with hand-written
> enter()/_exit() inside the body, bypassing the very accessors the commit says cannot be bypassed. [...]
> the instrumentation and the assertion are #ifdef DEBUG_VFS only, and DEBUG_VFS has been commented out at
> vfs.h:50 essentially forever and isn't built by CI - so the "teeth" never bite in any build anyone runs.
> [...] (The PR text's "taken at 14 sites" is also off - there are 6 acquisition sites.)

> **Commit 2 (strdup hoist)** **Correct and safe** [...] One nit [...] strdup() is unchecked, so on OOM
> dp->d_path becomes NULL and dentry_lookup()'s strncmp(dp->d_path, ...) will fault.

> dentry_children_remove() does LIST_REMOVE(entry, d_link) on each child but does not put them on the fake
> list - unlike dentry_remove() [...] So after renaming a directory, any child dentry that is still
> referenced will, on its final drele(), run LIST_REMOVE a second time on its hash link. [...] that's a
> write through a stale (possibly freed) pointer. That's a worse latent defect than the strdup() one, in
> the same function.

> there is at least one other AB-BA of the same class in this code (vnode_lock vs v_lock: vfs_vnode.cc:
> 111-118) [...] So the fix is right, but I wouldn't assume it's necessarily the wedge they saw.

**I VERIFIED EVERY CHECKABLE CLAIM AGAINST SOURCE. He is right on all of them:**
- not a leaf lock: `dentry_children_remove()` (`vfs_dentry.cc:128-139`) does `WITH_LOCK(dp->d_lock)` and is
  called from inside the hash-lock section at :164. CONFIRMED.
- DEBUG_VFS never builds: `fs/vfs/vfs.h:50` is `/* #define DEBUG_VFS 1 */` and a tree-wide grep finds no
  other definition, no Makefile, no CI. CONFIRMED - the assertion's teeth bite in no shipped build.
- vfs.h hygiene: my commit did add a second adjacent `#ifdef DEBUG_VFS` block, with the `bool` inside
  `__BEGIN_DECLS`. CONFIRMED.
- "14 sites": I count 7 acquisition sites, he says 6. Either way 14 is wrong. CONFIRMED.
- the NEW latent bug: `dentry_children_remove()` LIST_REMOVEs each child (:136) without the `fake` list,
  while `dentry_remove()` (:198-200) does it with the comment "put it on a fake list for drele() to work",
  and `drele()` LIST_REMOVEs again at :226. `LIST_REMOVE` (`bsd/sys/sys/queue.h:430`) writes
  `*(elm)->field.le_prev` unconditionally. CONFIRMED, mechanism and all - the `fake` list exists to prevent
  exactly this.
- the sys_rename route: `vn_lock(vp1)` at `vfs_syscalls.cc:730` is held across `lookup(dest)` at :746 and
  `dentry_move()`/`dentry_remove()` at :827-829. `ramfs_link` IS `vop_eperm` (`ramfs_vnops.cc:785`).
  CONFIRMED.
- his objection to MY Claim 1: correct - my commit message never states the necessary premise (two distinct
  dentries aliasing one vnode). CONFIRMED as a real hole in the reasoning.
- the second AB-BA: `vn_lookup()` takes `v_lock` under `VNODE_LOCK` (`vfs_vnode.cc:113-117`), `vput()` takes
  `VNODE_LOCK` under `v_lock` (:237-240). CONFIRMED present.
- Claim 2's contradiction: commit `ccfedefd4`'s message and `tests/tst-dentry-lock.cc`'s header both say the
  unfixed kernel wedges by timeout; the PR body line 71 says in bold "**The included stress test passes on
  unfixed code.**" CONFIRMED - flat contradiction in our own submission.

**DRAFT: `.local/maint-2026-09-20/pr-1502-reply.md`.** It needs three things from you:
- **Q1 (pivotal): he asks "what use case did it use?"** Our notes give the wedge (32 vCPU, forking server,
  184 backends, `dentry_hash_lock` held, all vCPUs in `do_idle`, empty wakeup mask, >1000 threads parked,
  ~27 GiB free) but NOT the filesystem (ZFS vs ramfs) or whether the workload used hard links / rename().
  That determines which of his two routes applies and whether his "second AB-BA" doubt is right. Supply the
  FS + operation mix (or the capture) and the reply gets written from evidence.
- **Q2: confirm the PR body is the correct half** of the test contradiction (I believe it is; the commit
  message and test header are stale text written before the test was run unfixed), and authorize fixing the
  message + header. He also asks how long the test runs - needs a timed run to quote.
- **Q3: scope** - fix both neighbour defects here, or fix the strdup (2 lines) and file the
  double-LIST_REMOVE as a follow-up? Recommendation: the latter.
11 work items are enumerated at the end of the draft, including the **#1503 blast radius**: it carries the
same apparatus widened to per-chain counting, where `owned()` on one mutex is NOT a drop-in (the predicate
is "holds ANY chain lock" and a thread can hold several) - preferred fix is `std::any_of` over
`dentry_chain_lock[]` calling `owned()`. #1503 also inherits the same overstated wording. Do not rework it
until #1502 settles.

### #1508 - @nyh, CHANGES_REQUESTED

Three inline on `fs/vfs/vfs_bdev.cc` plus a body that questions the PR's premise:

> **STYLE DIRECTIVE (worth applying repo-wide):** "Please ask your AI to avoid writing history lessons or
> changelogs in comments. The comment, if needed, should explain why some surprising code is correct - it
> shouldn't explain why one random mistake (which happens to be a mistake that existed in this code
> previously) is indeed a mistake. That's not only unhelpful, it's also confusing."

> After the fix, physio() is character-for-character `bdev_strategy_rw()` with `bio_cmd` derived from
> `uio_rw.` So the whole function can be: [6-line wrapper] [...] Moreover, using `bdev_strategy_rw()` will
> fix another bug - this version is missing a `uio_iovcnt > 0` check [...] so if uio_resid and the iovec
> list ever disagree the loop walks off the end of the array and dereferences garbage. **Trading a hang for
> an OOB read is a step sideways.**

> No bounds check. bdev_read/bdev_write both reject uio_offset + uio_resid > dev->size; physio() doesn't.

> #1424's comment says it "MUST go through physio() rather than bdev_read/bdev_write - those route through
> the OSv buf cache which is hard-coded to BSIZE=512". That's stale since his own c8c15304 [...] So it's
> worth asking whether physio() needs to be revived at all, or whether the Crucible driver should just use
> bdev_read/bdev_write and physio() should be deleted - 13 years dead is a decent argument for removal
> rather than repair.

**His central code request is ALREADY IMPLEMENTED:** `pr/physio-per-iovec-v2` (`1b9b5add8`, 11:16 EDT,
G-signed, merge-clean) reduces `physio()` to character-for-character the wrapper he proposed, which also
removes the history-lesson comment and inherits `bdev_strategy_rw()`'s `uio_iovcnt > 0` guard (the OOB fix).

**He is right that our #1424 justification is stale, verified against our own commit:** `c8c153047`
(2026-07-04) made `bdev_read()` take `bdev_strategy_rw()` whenever `bdev_uio_sector_aligned(uio)`
(`vfs_bdev.cc:104-105`), falling back to `bread()` only for unaligned offset or sub-sector length. So the
"must bypass a BSIZE=512 buffer cache" claim no longer holds for the aligned case.

**CALLER AUDIT (done this sweep) SUPPORTS DELETION:** `physio()` has **ZERO callers in upstream/master** -
only its definition (`vfs_bdev.cc:182`) and declaration (`include/osv/device.h:206`). Other `physio` greps
are unrelated (`vdev_disk_physio()`, and `zvol.c`'s classic 6-arg BSD `physio(zvol_strategy, ...)`, which is
not in the build). The ONLY real caller is #1424's Crucible driver: `crucible_read`/`crucible_write` at
`drivers/crucible-blk.cc:217,228`, each a one-line `return physio(dev, uio, ioflags);`. So deletion is a
2-line driver change plus a removal.

**AND THE CRUCIBLE COMMENT IS STALE TWICE OVER** (worth conceding both): besides the buffer-cache claim, it
says physio "hands the whole uio to crucible_strategy() as a single bio, which is what we actually want
anyway" - but issuing ONE bio for a multi-iovec uio IS the bug #1508 exists to fix. The comment advertises
the defect as the feature.

**DRAFT: `.local/maint-2026-09-20/pr-1508-reply.md`.** Needs your decision: (1) DELETE `physio()` and point
Crucible at `bdev_read`/`bdev_write` (my recommendation - after the rewrite its only distinguishing
behaviour is the MISSING bounds check, i.e. its sole unique property is a bug), or (2) KEEP it as the thin
wrapper, add the bounds check, correct the #1424 comment. One check remains either way: whether Crucible can
present an unaligned uio (if so, `bdev_read` routes it through BSIZE=512 `bread()` and the original #1424
worry returns for that case). Plus (a)/(b)/(c) on where the bounds check goes.

### Re-checks (explicit ask)
- **#1439 signalfd - STILL STALE, unchanged.** CHANGES_REQUESTED, MERGEABLE, non-draft. Newest activity is
  my own 2026-09-08 correction comment. nyh's CHANGES_REQUESTED is from 2026-07-15; all 8 threads resolved,
  every one lastBy=gburd. Only a maintainer clears the flag. **He is active TODAY - this is now plausibly
  unblockable, but per the standing rule I did not nudge.**
- **#1464 disperse - APPROVED + CLEAN + MERGEABLE, unchanged.** Still literally one merge click.
  nyh APPROVED 2026-08-03T14:29:05Z. Given he is back and reviewing, this is the one to watch.
- **#1511 / #1512:** 0 comments, 0 reviews, 0 inline. Still awaiting first review. Both MERGEABLE.
- **#1458:** both comments (5718101962 and the new 5749965679) unanswered, 0 reactions, never edited. All
  five issue comments on #1458 are gburd's.

### Posted this sweep: NOTHING
No trivially-factual correction was available - the factual errors nyh found are in commit messages and PR
descriptions that need rewriting, not one-line fixes, and every reply depends on a decision or on evidence
only you have. No nudge posted (standing rule), including on #1439/#1464.

=======================================================================
## TASK 2 - Upstream-filed dependency issues
=======================================================================

### FINDING: still exactly one outstanding external filing, still dormant. Null result, ninth consecutive check.

- **gkostka/lwext4 #100** (ext4_ext_check OOB read): OPEN, **0 comments**,
  `created_at == updated_at == 2026-07-14T14:24:21Z` - byte-identical again. Upstream `gkostka/lwext4`'s
  newest commit is 2022-09-22, so the repo has been dead ~4 years; no reply is expected. Our fix ships via
  the `osvunikernel/lwext4` fork OSv actually builds from, and as OSv PR #1449. Non-blocking. Leave open as
  the disclosure record.
- **No other OSv-related filings.** A repo-wide search of my authored issues/PRs outside
  `cloudius-systems/osv` found nothing else OSv-related open (the rest are libdb, pgrust, turbovec,
  dagster, pgcat etc., unrelated to this program). Zero OpenZFS filings by us.

=======================================================================
## TASK 3 - Dependency currency (report only, nothing bumped)
=======================================================================

| dep | pinned on upstream/master | newest available | gap | risk | status |
|-----|---------------------------|------------------|-----|------|--------|
| OpenZFS (`modules/open_zfs/openzfs`) | `83020cf82` = **zfs-2.4.3** (`.gitmodules branch = zfs-2.4.2`) | **zfs-2.4.4** (`71a9f9578`, 2026-08-21) | 1 patch release | LOW | **PREPARED in open #1488** (`cb23ebdf3`, MERGEABLE + CLEAN): gitlink -> `71a9f9578`, `.gitmodules branch` -> `zfs-2.4.4`. Maintainer-gated. |
| lwext4 (`modules/lwext4`) | **UNPINNED** - bare `git clone --depth 1` of `osvunikernel/lwext4` | fork tip `6f6d8f7c5` (2025-07-04) | n/a | **MEDIUM** (reproducibility, not security): two builds of the same tree can link different lwext4 revisions and neither records which | **PREPARED in open #1500**: pins `lwext4_commit?=6f6d8f7c50...` = current fork tip, overridable. Merge-clean. |
| `external/x64/acpica` | `3e45e0f2383c` | `3e45e0f2383c` | **0 - current** | none | fork tip, nothing to do |
| `kbuild` | `9f1d27a86879` | `9f1d27a86879` | **0 - current** | none | fork tip, nothing to do |
| `musl_1.2.1` (`osvunikernel/musl`) | `73cc775bee53` ("release 1.2.1", 2020-08-04) | `a5aff1972c9e` (2020-09-17) | **49 commits behind** | LOW-MEDIUM, unquantified | the fork itself is frozen at 2020; the 49 commits are fork-local work after the 1.2.1 release tag. Not evaluated. Do NOT bump without a build+test pass - musl is the libc. |
| `musl_0.9.12` | `372a948b8139` | n/a (legacy) | - | none | legacy path, untouched |
| `modules/httpserver-html5-gui/{osv-gui,swagger-ui}` | `c93b2f5cf`, `5d7010b96` | not checked | - | low (GUI submodules, not in the critical path) | no action |

Note the cosmetic inconsistency in #1488's favour: master's `.gitmodules` says `branch = zfs-2.4.2` while
the recorded gitlink is the 2.4.3 tag. #1488 fixes both to 2.4.4 together. Nothing bumped by me.

=======================================================================
## TASK 4 - Remaining plan: DONE / IN-PROGRESS / NOT-STARTED / BLOCKED
=======================================================================

### DONE + VALIDATED, filed upstream, awaiting maintainer
- **#1502** vfs dentry AB-BA deadlock fix - **NOW CHANGES_REQUESTED**; the code rework is written
  (`pr/vfs-dentry-lock-order-v2`), the text corrections are not. See Task 1.
- **#1508** physio one-bio-per-iovec - **NOW CHANGES_REQUESTED**; rework written
  (`pr/physio-per-iovec-v2`), but the existential question (delete physio?) is open. See Task 1.
- **#1464** load-balancer disperse - APPROVED + CLEAN. One click.
- **#1511** adaptive per-CPU idle-spin (supersedes the closed #1501) - MERGEABLE, clean, 0 reviews.
- **#1512** durable-write syncwrite bench isolate - MERGEABLE, the instrument behind #1511's table.
- **#1472** idle-CPU pull work-stealing, **#1480** condvar lock-before-waitqueue, **#1484** null-thread wake
  guard, plus the large ready family (#1477, #1479, #1481-#1486, #1490-#1499, #1503-#1507, #1509).
- **#1488** OpenZFS 2.4.4, **#1500** lwext4 pin - both merge-clean, maintainer-gated.
- **The footprint fix: VALIDATED END-TO-END.** Per-backend 247 MB -> **9.4-12.5 MB, FLAT from 42 to 202
  address spaces**; 74 backends (the exact pre-fix OOM count) now completes, 202 run, 576 backends reached
  with **42.4 GB still free** (so 576 is a floor, stopped by `max_connections=600`); VU192 recycled 1.43 TB
  of churn against 1.66 GB live; zero OOM/EMFILE/abort. `bank/fork-footprint-reduction-signed`, 5 commits
  G-signed. **BLOCKED on #1458 composition, not on work.**
- **Leak #1** (fd/gfdt EMFILE), 400-round A/B validated - `bank/fork-fd-reap-leak-reviewready`, lands as S5.
  **BLOCKED on #1458.**
- **Leak #2** (fork-arena memory), 5-gate validated (400 rounds / 26,181 backends) + 8 cross-AS coherence
  scopings - `bank/fork-arena-real-reclaim`, lands as S8. **BLOCKED on #1458.**

### ANSWERED (questions closed by measurement)
- **#3 "does OSv scale like Linux?" -> NO.** OSv is FLAT 151k/166k/153k/150k across VU32-192 at
  **0.42-0.73x Linux**, at only **~54-59% guest CPU with NVMe pinned at 95-97%**, while Linux rises to 361k
  at VU128 on 84-88% CPU with the device under half utilised. The ratio DIVERGES rather than converging, and
  every cell was DRIVER_OK, so it is not a client-side wall. Fixing the memory wall revealed a throughput
  ceiling underneath it.
- **#4 "what is the VU32 factor?" -> ANSWERED, and it is NOT the commit path.** The decisive test removed
  durability and **WIDENED** the gap (0.49x -> **0.063x**): OSv collapses to 37.7k at **6% CPU with an IDLE
  device** while Linux doubles to 600k and CPU-saturates. That is WAITING, not working. The factor is the
  **ASYNC WRITE-COMPLETION path (io_uring / ZFS writeback)**, NOT ZIL/WAL as suspected for weeks.
  `LWLock/AioUringCompletion` is in the top-3 waits of BOTH OSv cells and NEITHER Linux cell.

### IN-PROGRESS (owned by another agent, untouched by me)
- **The AioUringCompletion liveness wedge** - NEW bug, 3 of 11 high-VU cells stuck at 99.2-99.5% in
  `AioUringCompletion` with device idle, CPU idle, memory healthy. Root-cause run LIVE on
  `i-0f6bc380d2ff4c4d9` + `i-031500bbc802fdadb` since 14:06Z today. Source recon already banked in
  `.local/WRITE-COMPLETION-BRIEF.md` (prime suspects: the CQ-overflow deque regime under `ctx->mtx`, and
  `wq_wait[cls].wake_one()` single-waiter wake on a shared work queue).

### BLOCKED
- **THE KEYSTONE: #1458 fork composition (#1455/#1456).** The S1..S8 decomposition proposal (comment
  5718101962, 2026-09-17) has no reply and no reactions after 3 days; the new footprint/scaling comment
  (5749965679, today) likewise. Until this lands, **nothing in the fork generation can open as a mergeable
  PR** - the three validated fixes above are strictly stacked on unmerged #1455/#1456. **This is the single
  highest-leverage thing a maintainer could unblock, and the maintainer is now active.**
- **#1439** stale CHANGES_REQUESTED - maintainer-only action.
- The NUMA family (#1438/#1441/#1445) needs a substantive rebase onto master's SRAT/SLIT layer (the
  `core/numa.cc` add/add conflicts). Not urgent.

### NOT STARTED
- **M2** and **PGXN** - unchanged, still not started.
- Roadmap B/C/D items (Azure, NUMA per-node pools beyond #1445, hot-plug, GPU/VFIO, libaio C1, mremap C2,
  modern FS syscalls C3, splice C4, IPv6 D1 beyond #1442, ext4 D2) - unchanged.

=======================================================================
## TASK 5 - Draft-PR currency
=======================================================================

**upstream/master is STILL `0e34e4dc2b278b7f64e4169abbf297b7de46fb6b`** (2026-08-17, 34 days). It did not
move, so **no draft needs a refresh for staleness and no rebase is required anywhere.**

Verified every CONFLICTING PR with `git merge-tree --write-tree --messages upstream/master <PR head>` from a
worktree at upstream/master (`/tmp/adapt-master`), fetching the actual PR heads rather than local branches:

| PR | gh says | merge-tree says | conflicting files |
|----|---------|-----------------|-------------------|
| #1475 | CONFLICTING | CONFLICT x1 | `libc/signal.cc` |
| #1456 | CONFLICTING | CONFLICT x1 | `libc/signal.cc` |
| #1438 | CONFLICTING | CONFLICT x2 | `core/numa.cc`, `include/osv/numa.hh` |
| #1445 | CONFLICTING | CONFLICT x2 | `core/numa.cc`, `include/osv/numa.hh` |
| #1441 | CONFLICTING | CONFLICT x3 | + `tests/tst-numa.cc` |
| #1458 | CONFLICTING | CONFLICT x16 | `.gitignore`, `.gitmodules`, `Makefile`, `apps`, ... (expected - tracking branch) |
| **#1449** | **CONFLICTING** | **CLEAN** | - auto-merges `modules/libext/ext_vnops.cc` + `modules/tests/Makefile` |
| **#1440** | **CONFLICTING** | **CLEAN** | - auto-merges `modules/tests/Makefile` |

**So 6 PRs genuinely conflict, not 8: GitHub's flag is STALE on #1449 and #1440.** Both are the
`modules/tests/Makefile` cases the prior sweep flagged; they now merge clean. A no-op push or a maintainer
recompute would clear the flag. I changed nothing.

All key candidates verified CLEAN: `pr/vfs-dentry-lock-order`, `pr/vfs-dentry-lock-order-v2`,
`pr/vfs-dentry-perchain`, `pr/physio-per-iovec-v2`, `pr/sched-adaptive-idle-spin-master`,
`bench/syncwrite-mt`, `pr/openzfs-2.4.4`, `pr/pin-lwext4`, `pr/signalfd`, `pr/sched-load-balance`.

=======================================================================
## TASK 6 - Sync osv + osv-apps
=======================================================================

`git fetch --all --prune` in `~/ws/osv` and `~/ws/osv/apps` (the osv-apps checkout is the submodule at
`/home/gburd/ws/osv/apps`; `~/ws/osv_1/apps` and `~/ws/osv_2/apps` also exist as other checkouts).

**osv:** `upstream/master` = `master` = `origin/master` = `gh-fork/master` = **`0e34e4dc2`. Zero divergence,
0 ahead / 0 behind.** Nothing to push. `osv-improvements` differs across mirrors (local `41e04deb7`,
origin `65cde02bf`, no gh-fork ref) - pre-existing, not part of this sweep's scope, not touched.

**osv-apps:** `cloudius/master` = `b2d53b348c15` ("fio: switch to github", 2026-08-02).
- `origin/master` (codeberg) = `gh-fork/master` = `0b98404febe7`.
- **STILL EXACTLY 1 COMMIT BEHIND, and still a plain fast-forward** - `git merge-base --is-ancestor` returns
  true for both mirrors, and the single missing commit is `b2d53b3` itself. The prior sweep's finding holds
  unchanged. **Not pushed** (report-only per brief).
- Local `master` in the checkout is already at `b2d53b348c15`.

**osv-apps #73** (`postgres18-musl`): OPEN, **isDraft=true**, MERGEABLE, `mergeStateStatus=CLEAN`, head
**`3f93f43f4f44` - the pin in the brief is still current** (unchanged since 2026-09-11T13:48:05Z, no reviews,
no comments). Held on the OSv fork/COW landing, i.e. on the same #1458 keystone. Note `3f93f43` does NOT
contain `cloudius/master`'s newest commit, which is harmless for a draft but will want a rebase before it
merges. `gh-fork/wip/postgres18-musl-demo` = `3f93f43f4f44` (in sync);
`gh-fork/wip/postgres18-musl-demo-synced` = `c5c179075ca8` (a separate older ref).

=======================================================================
## TASK 7 - Open PRs for finished + unblocked features?
=======================================================================

### FINDING: no NEW PR should open. The two best candidates are REWORKS OF PRs ALREADY UNDER REVIEW, which is strictly better than opening anything.

Enumerated every local branch with 0 commits behind upstream/master, cross-referenced against the 57 filed
PR head refs. 12 unfiled candidates exist. Dispositions:

| branch | disposition |
|--------|-------------|
| `pr/vfs-dentry-lock-order-v2` (`d6166ed3a`) | **PUSH TO #1502's HEAD, do not open a new PR.** It is the answer to nyh's live review. Merge-clean, G-signed. Gated on the Q1/Q2/Q3 decisions + the text corrections. |
| `pr/physio-per-iovec-v2` (`1b9b5add8`) | **PUSH TO #1508's HEAD, do not open a new PR** - and only after the keep-or-delete decision, since "delete physio()" would close #1508 instead. Merge-clean, G-signed. |
| `pr/sec-ext4-readlink-v2`, `pr/zfs-provider-manifest-v2`, `pr/idle-spin-tunable`, `pr/sched-idle-spin-v2`, `pr/sched-adaptive-idle-spin` | superseded variants of filed PRs (#1449, #1497, #1511). Do not open - would duplicate. |
| `pr/dentry-lock-order` | older sibling of #1502/#1503's branch pair. Do not open. |
| `cru-final` | the #1424 Crucible line. Do not open - and #1508's review directly affects its `physio()` usage. |
| `wip/native-zfs-fixes` | the RDSEED work. **Per `.local/QUEUED-FOLLOWUPS.md` item D: fold into #1492, do NOT open as a competing PR** - and only after #1492's review settles. Unchanged. |
| `wip/pg-zfs-readpath` | `vn_access` superuser discretionary access - unvalidated as a standalone upstream change. Do not open. |
| `zfs-aarch64-v2` | 5 commits, overlaps #1459's aarch64 line. Do not open without a rebase decision. |
| `bench/syncwrite-mt` | **already filed as #1512 last sweep.** Do not duplicate (brief confirms). |

Correctly NOT opened per brief: the two leaks and the footprint fix (all three blocked on the #1458
composition decision), and 4a (retired, superseded by #1478).

**Zero new PRs opened. Zero drafts opened.** The highest-value action available is not a new PR at all - it
is answering the two live reviews.

=======================================================================
## TASK 8 - Local + LAN tidy
=======================================================================

### Worktrees: 12 listed, ALL directories present, 0 prunable
`git worktree prune --dry-run -v` = no output. Every path verified on disk. (The brief said 11; there are
12 - `/tmp/rxpool-wt` is the extra, see below.)

| worktree | branch | ahead/behind upstream/master | note |
|----------|--------|------------------------------|------|
| `~/ws/osv` | `wip/pg-rx-directwake` | 87a/24b | main, 118 dirty paths (live work, untouched) |
| `.local/worktrees/dentry` | `pr/dentry-lock-order` | - | **KEEP - #1502/#1503 are under live review** |
| `.local/worktrees/fork-arena` | `integ/pg-fork-arena` | 41a/24b | keep (blocked-on-#1458 line) |
| `.local/worktrees/forksym` | detached `5761ed02c` | - | keep |
| `.local/worktrees/inotify` | `pr/inotify` | 1a/12b | 2 lines behind #1440's head; #1440 now merges CLEAN |
| `.local/worktrees/iouring` | `bank/iouring-completion-fix` | 172a/24b | **LIVE - agent-iouring owns it. DO NOT TOUCH** |
| `.local/worktrees/ipv6-port` | `pr/ipv6-forward-port` | 38a/30b | keep (#1442) |
| `.local/worktrees/signalfd` | `pr/signalfd` | 1a/2b | keep (#1439 stale-flag) |
| `/tmp/adapt-master` | `pr/sched-adaptive-idle-spin-master` | 1a/0b | **I used it this sweep for merge-tree. Keep for now** |
| `/tmp/adapt-pr` | `pr/sched-adaptive-idle-spin` | 2a/0b | #1511 is filed from this line |
| `/tmp/fpwt` | `bank/fork-footprint-reduction` | 172a/24b | **DO NOT TOUCH per brief** |
| `/tmp/rxpool-wt` | `rxpool-fix` | 129a/24b | **REPORT FOR YOUR DECISION:** last touched 2026-08-29 (22 days), only 324K, and `rxpool-fix` is 129 ahead / 24 behind - superseded by the `wip/pg-rx-*` line the main worktree is on. Looks spent. **Not removed** - judgment call, and it is in `/tmp` which is under no pressure. |

### /tmp OSv scratch
`df -h`: `/` = `/tmp` = `/home` on one 3.7T volume, **1.4T used, 2.1T available, 40%. Zero pressure**, so
the correct lazy action is to remove nothing that is not certainly dead. `/tmp` total is 454G, dominated by
non-OSv work (`solnix-*` 3x74G, `tui2/tui3-build` 33G, `noxu-xbench` 11G, `usb-*` 16G).

**I removed NOTHING this sweep.** Everything I could have removed is either (a) tiny enough that removal
reclaims nothing measurable, or (b) not provably dead while the io_uring run is live. Specifically:
- **NOT touched, brief-protected or live-agent-adjacent:** `/tmp/fpwt`, `/tmp/rxpool-wt`,
  `/tmp/adapt-{master,pr}`, and every `*iouring*`, `*scale*`, `*footprint*`, `*leak*`, `*cwwake*` entry -
  including `/tmp/leakhunt-{ip,patch}`, `/tmp/build_leak`, `/tmp/*leak*.{sh,c,py,log}`, `/tmp/scale_bench*`,
  `/tmp/scale_ns`, `/tmp/*scale*.{sh,sql,py}`, `/tmp/pc-osv-vu*.log` (the scaling console captures).
- **Candidates that ARE almost certainly dead but reclaim ~0 bytes, so left alone:** 15 empty
  `/tmp/rt[bpq]-*` dirs (ZFS build-test scratch, 2026-09-07, all verified 0 entries), 22 empty
  `/tmp/pgbench-results-*` dirs, and empty `/tmp/{hammerdb,zfs-image,dlfork,dlfork-repro,bqscale,smokelzfs,
  xml2hammer}`. Say the word and they go in one `rmdir`; with 2.1T free there is no reason to.
- **NOT OURS, never touched:** the libdb/opstats/ssi/gi/fa/wtail/gc-wt and recno/mvcc/getnext files, and all
  solnix/larql/cosmic/catam/pgweave/tui material.
- My own scratch from this sweep (`/tmp/osv-events*.json`, `/tmp/osv-human*.txt`, `/tmp/osv-open-prs.txt`,
  `/tmp/notes-*`, `/tmp/filed-branches.txt`) is small and left in place; `/tmp/notes-refresh.idx` was
  removed after use.

### EC2 - REPORT ONLY (launched 0, terminated 0, tagged 0, ssh'd 0)
Requires `AWS_PROFILE=hotdog` (the default profile has no credentials). Scanned us-east-1, us-east-2,
us-west-1, us-west-2, eu-west-1:
- **`i-0f6bc380d2ff4c4d9` (c5.9xlarge, Owner=agent-iouring, 14:06:47Z)** and
  **`i-031500bbc802fdadb` (m5d.metal, Owner=agent-iouring, 14:06:45Z)**, both `running` in us-east-2 - the
  LIVE io_uring write-completion root-cause run. Brief-named off-limits. **Not touched in any way.**
- NOT OSv, not mine, untouched (us-east-2): `undo-amtest-*`, `libdb-log`, `libdb-test`, `ra-pg19-*`,
  `pgweave-dev-*` x2, `undo-recnodef-*`.
- **0 instances in us-east-1, us-west-1, us-west-2, eu-west-1.**
- **0 orphan instances. 0 `available` (unattached) volumes in all five regions.** Clean.
- **0 `Owner=agent-maintsweep*` instances.** Nothing of mine anywhere.
- LAN hosts touched: NONE.

=======================================================================
## TASK 9 - Notes record refreshed and pushed to BOTH mirrors
=======================================================================

### DONE. `notes/pg-campaign-record`: `1398cc43e` -> **`5972d9241`**, G-signed, fast-forward, both mirrors.

Selection (deliberately conservative):
- Started from the 80 uncommitted `.local` changes, filtered to `*.md *.sh *.py *.txt *.json *.diff *.patch`
  and excluded `.local/worktrees` and `.local/pg18` -> 60 files.
- **Then excluded the 38 `.local/iouring/*` files**, because `.local/iouring/*` is on the brief's
  DO-NOT-TOUCH list and belongs to the LIVE agent-iouring run. Committing a live run's harness mid-flight
  would bank a moving target and could collide with that agent. **Those 38 files are still uncommitted and
  should be banked by whoever owns that run, or by the next sweep once the boxes are down.**
- Net: **22 files, 589 insertions**: `WRITE-COMPLETION-BRIEF.md`, `CAPTURE-STATUS-2026-09-20.md`,
  `BLOCKED-WINS-2026-09-20.md`, `PR1502-REVIEW-ANALYSIS.md`, `maint-2026-09-20/pr-1502-reply.md`, and 17
  `zilab/raw/x/probe-*.json` per-cell ZIL probe files.
- Verified every file is text (`file --mime-encoding`), none binary, total 145,757 bytes. No `*.tgz`,
  `*.gz`, `env.boxes`, `instance.id`, `*.pub`, `*.ndjson` or build artifact included.

Mechanics:
- Built with plumbing (`GIT_INDEX_FILE` + `read-tree` + `update-index` + `commit-tree -S`) so the main
  worktree's index and 118 dirty paths were never disturbed. Confirmed afterwards: 0 staged by me, still on
  `wip/pg-rx-directwake`, same dirty count.
- **Base was already correct** - the notes branch's parent is `upstream/master` and its `apps` gitlink is
  `b2d53b348c15`, identical to `upstream/master:apps`, so the pre-push hook had nothing to reject. The
  dangling `57c6079843` problem from the first attempt does not recur. All 8 gitlinks verified against
  upstream's before pushing.
- Signature: `%G?` = **G**, `greg@burd.me`. No em/en dashes in the message (checked).
- Pure fast-forward (`merge-base --is-ancestor` true), so `--force-with-lease=<old sha>` was belt-and-braces
  only; **no bare `--force` anywhere**.
- Pushed to **origin** (codeberg, private) and **gh-fork** (github, public), both `1398cc43e..5972d9241`.
  Re-fetched and confirmed both remote refs = `5972d9241`, signature G.

Leak posture: scanned the 22 files for AWS keys, private keys, `ghp_` tokens, bearer tokens and
`password=` - **zero hits**. They DO contain 2 instance ids (`i-00adec9774170bad2`, `i-0dc1629a58a7d6458`)
and private/link-local IPs (192.168.100.x, 127.0.0.1) - acceptable for these mirrors per the brief, but
**these notes must NEVER be pasted into a public PR body.** `gh-fork` is public, so the ids are now
public-visible; that matches the existing 1568-file baseline and your standing decision, flagged here for
the record.

=======================================================================
## CHANGES MADE THIS SWEEP (safe + clearly correct only)
=======================================================================
1. `git fetch --all --prune` in `~/ws/osv` and `~/ws/osv/apps`.
2. Fetched PR heads to `refs/tmp/*` in `/tmp/adapt-master` for merge-tree analysis (scratch worktree only).
3. **Task 9: committed 22 notes/evidence files as `5972d9241` (G-signed) and fast-forwarded
   `notes/pg-campaign-record` on BOTH origin and gh-fork.**
4. Wrote `.local/maint-2026-09-20/pr-1502-reply.md` and `.local/maint-2026-09-20/pr-1508-reply.md` (drafts).
5. Wrote this report.

NOT done (by rule, or needing your judgment):
- **Nothing posted to any PR.** Both live reviews need your decisions, and the factual corrections nyh found
  live in commit messages / PR descriptions, not in one-line editable text.
- No nudge on #1439 or #1464 (standing rule), despite the maintainer being active today.
- No rebase, no force-push, no merge, no PR opened, no PR body edited, no dependency bumped.
- No worktree removed (`/tmp/rxpool-wt` reported for your decision), no `/tmp` entry removed, no `git add -A`,
  no `.gitignore` touched.
- The 38 `.local/iouring/*` files left uncommitted (live-agent-owned).

=======================================================================
## WHAT I WOULD DO NEXT, IN ORDER
=======================================================================
A. **Answer #1502.** Needs Q1 (the field use case: filesystem + hard-link/rename mix), Q2 (confirm the PR
   body is the correct half of the test contradiction), Q3 (scope of the two neighbour fixes). The code half
   is already written. This is a live conversation with the only person who merges our work - it is worth
   more than any other item on the board.
B. **Decide #1508: delete `physio()` or keep the wrapper.** The caller audit says deletion costs 2 lines in
   #1424's driver, and his argument is sound. This also changes #1424's shape.
C. **Watch for more reviews** - he moved #1502 -> #1508 in 16 minutes and may keep going. Re-poll with the
   events API, not just the comment endpoints.
D. **#1458 is still the keystone**, and the maintainer is finally at the keyboard. Nothing else unblocks the
   three validated fork fixes.
E. Bank the 38 `.local/iouring/*` harness files once that run finishes.
