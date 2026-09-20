# OSv upstreaming maintenance/tidy sweep - 2026-09-21

Follow-on to `.local/maint-2026-09-20-sweep.md`. All facts re-verified from the APIs and from source during
this sweep. Read-heavy.

**CLOCK NOTE:** this host's UTC clock reads **2026-09-20 17:0x UTC** while the sweep is labelled 09-21. The
prior sweep ran at 14:48-15:40Z on 09-20, so this sweep sits roughly **90 minutes after it**, not a day. That
matters for one conclusion: "no new reviewer activity" covers ~1.5h of wall time, not 24h. Filed under the
09-21 name as instructed, flagged so the interval is not overstated.

**Changes made:** `git fetch --all --prune`; PR-head fetches into `refs/tmp/*` in a scratch worktree; the
task-9 notes commit + push to both mirrors; 3 draft files. **Nothing posted to any PR, nothing rebased, no
force-push to any PR branch, no dependency bumped, no box touched, no worktree removed, no /tmp entry
removed.** Main worktree's dirty paths untouched (plumbing index used).

**DID NOT TOUCH (per brief):** `i-0f6bc380d2ff4c4d9` + `i-031500bbc802fdadb` (Owner=agent-iouring, live);
`bank/iouring-completion-fix`, `bank/fork-*`, `bench/leakhunt`, `core/{io_uring,fork_arena,sched,pagecache}.cc`,
`.local/{iouring,scale,footprint2,cwwake,gates,leak2}/*`. `.local/iouring/*` again EXCLUDED from the notes
commit.

Environment: SSH agent `/run/user/1000/wezterm/agent.3913155`; `AWS_PROFILE=hotdog` required for EC2.

=======================================================================
## HEADLINE - the reviews are answered, but ONE correction never reached the code
=======================================================================

The events-API check is a **clean null**: no nyh/wkozaczuk activity since 15:18:32Z, no reply to either open
question, no first review on #1511/#1512, no movement on #1458.

The sweep's real finding is in our own tree. **nyh's three corrections on #1502 were applied to the commit
messages and the test header, but NOT to the source comments in `fs/vfs/vfs_dentry.cc`** - and those comment
lines are added by the PR's own diff, so they are what he reads on a re-look and what persists after merge.
Four disproved claims are still in the tree at `c7ab5929e`, including the exact "**dentry_hash_lock is a leaf
lock**" sentence he refuted, twice, and the production observation that comment 5750804145 publicly
reattributes to commit 2. **#1503 inherits all four.** Full analysis + a comments-only patch:
`.local/maint-2026-09-21/PR1502-COMMENT-GAP.md` and `pr-1502-comment-fixes.diff`. **Not pushed** - reason in
Task 1.

=======================================================================
## TASK 1 - Reviewer comments
=======================================================================

### Methodology applied in the prescribed order: EVENTS API FIRST.

`repos/cloudius-systems/osv/events` (121 events, full pagination) plus `users/nyh/events/public` and
`users/wkozaczuk/events/public`, THEN the per-PR comment/review/inline endpoints, for all 57 open PRs.

### FINDING: NO new reviewer activity. Newest nyh event is still `2026-09-20T15:18:32Z`.

- Non-gburd events repo-wide: **15 total**. The 10 newest are nyh's two reviews and six inline comments from
  14:32-15:18Z on 09-20 - the ones already addressed. Before those: `jlinenkohl` fork+star (09-11),
  `cataggar` star (09-04), `mars-tx` (08-30), `gregl83` (08-21). No human review activity other than nyh's.
- **`users/wkozaczuk/events/public` returns 0 events entirely.** The merger is still absent; last merge
  2026-08-17. Nothing in his feed to confirm he has even looked.
- No PENDING review is in flight: the events API shows no `PullRequestReviewCommentEvent` newer than
  15:16:41Z, and every one of those six is already visible through the normal endpoints (so the FALSE-NULL
  condition that hid the last review is **not** currently active). Re-checked after the comment scan.

### Replies to my two open questions: NONE.

| question | asked in | answered? |
|----------|----------|-----------|
| #1502: the pre-existing `fake`-list double-`LIST_REMOVE` - own PR against master, or fold in? | comment 5750841798, 15:47Z | **no** |
| #1508: delete `physio()` entirely, or keep the minimal repair? | comment 5750850279, 15:48Z | **no** |

No reply to any of the six replies posted (5750714474 / 5750804145 / 5750841798 on #1502;
5750717459 / 5750736049 / 5750850279 on #1508). Not nudged, per the standing rule.

### First review on #1511 / #1512 / #1458: NONE.
- **#1511** `pr/sched-adaptive-idle-spin-master` @ `2be3701f0`: 0 issue comments, 0 inline, 0 reviews. MERGEABLE/CLEAN.
- **#1512** `bench/syncwrite-mt` @ `1cdbe3541`: 0 / 0 / 0. MERGEABLE/CLEAN.
- **#1458:** all 5 issue comments are gburd's. The S1..S8 keystone (5718101962, 09-17) and the
  footprint/scaling update (5749965679, 09-20) both have **0 reactions** (checked the reactions endpoint
  directly) and no reply. **No movement on the keystone.**
- Neither #1511 nor #1512 nor #1502/#1508 has any CI: "no checks reported" on all four. No CI signal exists
  on this repo for our branches, so "merge-clean" is a merge-tree fact only, never a green build.

### Re-checks (explicit ask)
- **#1439** signalfd: `MERGEABLE` + `CLEAN` + `reviewDecision=CHANGES_REQUESTED`, unchanged. nyh's flag is
  from 2026-07-15T12:54:06Z; every subsequent comment on the PR is gburd's (newest 2026-09-08). **Still
  stale, still maintainer-only to clear.** Not nudged.
- **#1464** disperse: `MERGEABLE` + `CLEAN` + **`APPROVED`** (nyh, 2026-08-03T14:29:05Z), unchanged. **Still
  literally one click.** Not nudged.

### Verified-correct items (worth recording as clean)
- **#1508 is in good shape.** `75bb43bf6` is `physio()` = exactly nyh's proposed 6-line wrapper plus the
  bounds check, `+4/-37` against master, and the history-lesson comment is gone. The full diff carries **no
  residual comment prose at all**, so the #1502 problem does not exist here. Bounds check matches
  `bdev_read`/`bdev_write` byte-for-byte (`uio_offset + uio_resid > dev->size` -> `EIO`, `uio_offset < 0` ->
  `EINVAL`, `uio_resid == 0` -> `0`). All 3 commits `%G?`=G, no em-dashes.
- **#1502's code is right** and the inline nitpicks are genuinely resolved: `vfs_dentry_hash_lock_held()` is
  `return dentry_hash_lock.owned();`, the `__thread` depth counter and the duplicate `extern` are gone. All 4
  commits `%G?`=G, no em-dashes. The problem is prose only.
- **The "14 sites" number: nyh is right and I was wrong twice.** Counting actual acquisitions at `c7ab5929e`
  (`dentry_hash_lock_acquire()` + `WITH_LOCK(dentry_hash_lock)`) gives **exactly 6**, matching his count, not
  the 7 the prior sweep asserted. If a correction is posted, say 6.

### POSTED THIS SWEEP: NOTHING.
No trivially-factual correction was available in a form that is safe to post alone. The one substantive
finding (the comment gap) needs a **code change**, not a comment - and posting "the comments are also fixed"
before the push is precisely the claim-ahead-of-reality pattern that caused the original review. The
"6 not 7 sites" correction is real but too small to spend a comment on; fold it into the next push.

### WHY THE COMMENT PATCH WAS NOT PUSHED (judgment call, flagged)
1. It rewrites commit 1 of a 4-commit series **under live review**, i.e. a second force-with-lease inside
   ~2 hours of the first.
2. A **PENDING follow-up review is invisible** (this sweep's own methodology rule); force-pushing under one
   can orphan his in-progress inline comments.
3. His answer to the `fake`-list question may reshape the series anyway - the comment pass then rides along
   in that rewrite for free.
Recommendation: fold it into the next #1502 rewrite when his answer lands. Details and the exact patch are in
`.local/maint-2026-09-21/PR1502-COMMENT-GAP.md`.

=======================================================================
## TASK 2 - Upstream-filed dependency issues
=======================================================================

### Null result, tenth consecutive check. Still exactly one filing, still dormant.

- **gkostka/lwext4 #100** (`ext4_ext_check` OOB read): `state=open`, **`comments=0`**,
  `created_at == updated_at == 2026-07-14T14:24:21Z` - byte-identical yet again, so **no activity of any
  kind**, not even a label. `gkostka/lwext4`'s newest commit is **`58bcf89a121b`, 2022-09-22**: the upstream
  repo is ~4 years dead and no reply should be expected.
- Status: **non-blocking, leave open as the disclosure record.** Our fix ships via the `osvunikernel/lwext4`
  fork OSv actually builds from, and as OSv PR #1449.
- **No other upstream filings.** Zero OpenZFS filings by us. Nothing else OSv-related open outside
  `cloudius-systems/osv`.

=======================================================================
## TASK 3 - Dependency currency (report only, NOTHING bumped)
=======================================================================

| dep | pinned on upstream/master | latest upstream | gap | risk | status |
|-----|---------------------------|-----------------|-----|------|--------|
| OpenZFS `modules/open_zfs/openzfs` | `83020cf8259d` = **zfs-2.4.3** (`.gitmodules branch = zfs-2.4.3`) | **zfs-2.4.4** = `71a9f9578616`, released 2026-08-21 | 1 patch release | **LOW** | **PREPARED in open #1488** (MERGEABLE+CLEAN): gitlink -> `71a9f9578`, `.gitmodules` -> `zfs-2.4.4`, plus 7 platform-layer files for the 2.4.4 API changes. Maintainer-gated. |
| lwext4 `modules/lwext4` | **UNPINNED** - bare `git clone --depth 1` of `osvunikernel/lwext4` (Makefile verified) | fork tip `6f6d8f7c509d` (2025-07-04) | n/a | **MEDIUM** (reproducibility, not security) | **PREPARED in open #1500** (`+10/-1` on `modules/lwext4/Makefile`), pins `lwext4_commit?=6f6d8f7c50...`, overridable. Merge-clean. |
| `external/x64/acpica` | `3e45e0f2383c` | `3e45e0f2383c` (2013-01-24) | **0 - current** | none | fork tip. Nothing to do. |
| `kbuild` | `9f1d27a86879` | `9f1d27a86879` (2024-12-05) | **0 - current** | none | fork tip. Nothing to do. |
| `musl_1.2.1` (`osvunikernel/musl`) | `73cc775bee53` (2020-08-04) | `a5aff1972c9e` (2020-09-17) | **49 commits** | LOW-MEDIUM, unquantified | fork frozen at 2020; the 49 are fork-local post-1.2.1 work. **Do NOT bump without a full build+test** - it is the libc. |
| `musl_0.9.12` | `372a948b8139` | n/a (legacy) | - | none | legacy path. |
| `httpserver-html5-gui/osv-gui` | `c93b2f5cf80a` | `c93b2f5cf80a` (2017-01-17) | **0 - current** | none | fork tip. |
| `httpserver-html5-gui/swagger-ui` | `5d7010b96bf6` | `5d7010b96bf6` (2014-08-06) | **0 - current** | none | fork tip. |
| `apps` | `b2d53b348c15` | `cloudius/master` = `b2d53b348c15` | **0 - current** | none | see Task 6. |

**PRIOR-SWEEP ERROR CORRECTED:** the 09-20 sweep reported "master's `.gitmodules` says `branch = zfs-2.4.2`
while the gitlink is 2.4.3" and called it a cosmetic inconsistency in #1488's favour. **That is wrong.**
`git show 0e34e4dc2:.gitmodules` reads `branch = zfs-2.4.3`, matching the gitlink exactly. **There is no
inconsistency on master**, and #1488's `.gitmodules` hunk is a straight `2.4.3 -> 2.4.4` one-liner. Do not
repeat the 2.4.2 claim.

Note `zfs-2.4.99` exists as a tag but is the development branch, not a release (the releases endpoint lists
2.4.4 as newest). 2.4.4 remains the correct target.

=======================================================================
## TASK 4 - Remaining plan
=======================================================================

### DONE + VALIDATED, filed, awaiting the maintainer
- **#1502** vfs dentry AB-BA - review **ADDRESSED** (`c7ab5929e`, 4 commits, G-signed, force-with-lease; the
  only code change vs the reviewed head was the test header). **CAVEAT: the source comments were missed - see
  Task 1 / PR1502-COMMENT-GAP.md.** One open question to him.
- **#1508** physio - review **ADDRESSED** (`75bb43bf6`, `+4/-37`, G-signed, clean of comment prose). One open
  question to him (delete vs keep).
- **#1464** APPROVED + CLEAN - one click. **#1511** / **#1512** MERGEABLE, zero reviews.
- **#1472**, **#1480**, **#1484**, plus the ready family (#1477, #1479, #1481-#1486, #1490-#1499,
  #1503-#1507, #1509). **#1488** (OpenZFS 2.4.4) + **#1500** (lwext4 pin) merge-clean, maintainer-gated.
- **THE FOOTPRINT FIX - VALIDATED END-TO-END.** Per-backend private **247MB -> 9.4-12.5MB and FLAT from 42 to
  202 address spaces**; 74 backends (the exact pre-fix OOM count) completes; **576 concurrent backends with
  42.4GB still free** (a floor - stopped by `max_connections=600`, not by memory); VU192 recycled 1.43TB of
  churn against 1.66GB live; zero OOM/EMFILE/abort. `bank/fork-footprint-reduction-signed` @ `1480fbee1`,
  5 commits G-signed. **BLOCKED on #1458 composition, not on work.**
- **Leak #1** (fd/gfdt EMFILE, 400-round A/B) -> S5; **Leak #2** (fork-arena, 5-gate/26,181 backends, + 8
  cross-AS coherence scopings) -> S8. Both **BLOCKED on #1458**.

### ANSWERED BY MEASUREMENT (closed - do not re-litigate)
- **Does OSv scale like Linux? NO.** OSv is **FLAT** 151k/166k/153k/150k across VU32-192 at **0.42-0.73x**
  Linux, at only **~54-59% guest CPU with NVMe pinned at 95-97%**, while Linux rises to 361k at VU128 on
  84-88% CPU with the device under half utilised. The ratio **diverges**; every cell DRIVER_OK, so not a
  client wall.
- **The VU32 factor is NOT the ZIL/commit path.** Dropping durability **WIDENED** the gap (0.49x -> 0.063x):
  OSv collapses to 37.7k at 6% CPU with an idle device; Linux doubles to 600k and CPU-saturates.
- **The write bottleneck is NOT io_uring / async completion.** *Superseding the 09-20 framing.* PG18 has no
  async writes at all: `pgaio_io_start_writev()` has **zero callers**; all data-file writes go
  `smgrwrite -> mdwritev -> FileWriteV -> pwritev` **synchronously**, and io_uring is READS ONLY.
  `LWLock/AioUringCompletion` is PG's per-ring completion lock reaping other backends' **read** completions.
  H1 (CQ-ring full / overflow deque) measured dead: `cqfull=0, ovf_cur=0, ovf_max=0` across 76GB of writes /
  70k CQEs at 442 rings. H2 (wq wake starvation) measured dead: `wq_starve=0`, `wq_enq 70261` vs
  `wq_wake1 70200`. ZFS dirty throttle dead: `txdelay_calls=0`, `dirty_peak 492MB` vs `dirty_max 3276MB`.
  **The actual bottleneck is ZFS vdev write AMPLIFICATION (~4.8x), measured at two independent layers:**
  OSv issues ~97-101kB per device write vs Linux ~20-23kB on identical geometry (ashift=12, recordsize=8k);
  the in-ZFS probe shows `enq_wr_avg_kB=8` (PG's 8k logical writes arrive correctly) but `iss_avg_kB=146` and
  `agg_avg_kB=653`. That is why the NVMe pins at 95-97% while CPU idles at 54-59%.
  **Standing lesson: a wait-event NAME is not a mechanism - check the path is actually exercised.**

### IN-PROGRESS (another agent - untouched)
- **ZFS write-amplification root cause**, live on the two agent-iouring boxes since 14:06Z. Next steps
  already steered: the `zfs_vdev_aggregation_limit` A/B, and whether OSv differs from Linux because of a
  **default** or because the OSv vdev layer advertises different device capabilities (max I/O size / queue
  depth) - that distinction decides default-fix vs vdev-layer-bug.

### BLOCKED
- **THE KEYSTONE: #1458 / #1455 / #1456 fork composition.** S1..S8 proposal unanswered, 0 reactions, 4 days.
  Gates all three validated fork fixes (they are strictly stacked on unmerged #1455/#1456). Single
  highest-leverage unblock; cannot be forced.
- **Two open questions to nyh** (#1502 `fake`-list scope, #1508 delete-vs-keep). Both are his calls.
- **#1439** stale flag - maintainer-only.
- NUMA family (#1438/#1441/#1445) needs a substantive rebase onto master's SRAT/SLIT layer.

### NOT STARTED
- **M2 and PGXN** (every PGXN extension identical OSv-vs-Linux) - unchanged, **NOT STARTED**. The next
  milestone once the write-amplification work lands.
- Roadmap B/C/D: Azure, NUMA per-node pools, hot-plug, GPU/VFIO, libaio C1, mremap C2, modern FS syscalls C3,
  splice C4, IPv6 D1 beyond #1442, ext4 D2. (NTFS D3 remains DROPPED.)

=======================================================================
## TASK 5 - Draft-PR currency
=======================================================================

### `upstream/master` is STILL `0e34e4dc2b278b7f64e4169abbf297b7de46fb6b` (2026-08-17, ~34 days).
It has not moved, so **no PR needs a staleness refresh and no rebase is required anywhere.**

Re-verified every CONFLICTING PR with `git merge-tree --write-tree --messages upstream/master <PR head>` from
a worktree at `upstream/master` (`/tmp/adapt-master`), fetching **actual PR heads** into `refs/tmp/*`:

| PR | GitHub flag | merge-tree | conflicting files |
|----|-------------|-----------|-------------------|
| #1438 | CONFLICTING | CONFLICT x2 | `core/numa.cc`, `include/osv/numa.hh` (add/add) |
| #1441 | CONFLICTING | CONFLICT x3 | + `tests/tst-numa.cc` |
| #1445 | CONFLICTING | CONFLICT x2 | `core/numa.cc`, `include/osv/numa.hh` |
| #1456 | CONFLICTING | CONFLICT x1 | `libc/signal.cc` |
| #1475 | CONFLICTING | CONFLICT x1 | `libc/signal.cc` |
| #1458 | CONFLICTING | CONFLICT x16 | `.gitignore`, `.gitmodules`, `Makefile`, `apps`, ... (expected - tracking branch) |
| **#1440** | **CONFLICTING** | **CLEAN** (tree `e3823b487`) | - |
| **#1449** | **CONFLICTING** | **CLEAN** (tree `c8a1d469d`) | - |

**Confirmed independently: GitHub's flag is STALE on #1440 and #1449 - both merge clean. 6 PRs genuinely
conflict, not 8.** Second sweep in a row with the same result, so this is not a transient. A no-op push or a
maintainer-side recompute clears it; I changed nothing. All 6 real conflicts are pre-existing base drift
(NUMA family + fork stack), not new.

=======================================================================
## TASK 6 - Sync osv + osv-apps
=======================================================================

`git fetch --all --prune` in `~/ws/osv` (origin, upstream, gh-fork) and `~/ws/osv/apps` (origin, codeberg,
gh-upstream, gh-fork, cloudius). All succeeded.

**osv: ZERO divergence.**

    upstream/master = master = origin/master = gh-fork/master = 0e34e4dc2

No push needed, no force anywhere. (Consistent with the standing rule: local `master` mirrors
`upstream/master` exactly; fork-only work lives on `osv-improvements`.)

**notes/pg-campaign-record:** both mirrors were at `5972d9241` (G-signed, `greg@burd.me`) before this sweep,
its `apps` gitlink `b2d53b348c` = `upstream/master:apps`. **No local branch of that name exists** - it is
maintained by plumbing only. Advanced this sweep, see Task 9.

**osv-apps: the mirrors are STILL 1 commit behind and STILL fast-forwardable.**

| ref | sha |
|-----|-----|
| `cloudius/master` (upstream) | `b2d53b3` "fio: switch to github" |
| `codeberg/master` | `0b98404` |
| `gh-fork/master` | `0b98404` |

`git rev-list --left-right --count cloudius/master...codeberg/master` = `1  0`, and
`merge-base --is-ancestor codeberg/master cloudius/master` = **true**, so both mirrors fast-forward to
`b2d53b3` with **one commit, no force**. Unchanged from the last sweep. **Not pushed** (report-only task).

**osv-apps #73 pin: CURRENT.** PR #73 head = `3f93f43f4f44`, `state=open`, `mergeable=true`; the working
checkout `~/ws/osv/apps` HEAD = `3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3`. **Exact match**, and it is the
pin the campaign branches use. `gh-fork/wip/postgres18-musl-demo` also = `3f93f43`.

=======================================================================
## TASK 7 - Open PRs for finished + unblocked features
=======================================================================

### FINDING: nothing qualifies. Zero PRs opened. That is the correct answer, not an omission.

Audited all 43 local `pr/*`, `bank/*`, `integ/*` branches that are not the head of an open PR, against the
111 PRs gburd has ever filed:

- **Gated on the #1458 composition decision (explicitly excluded by the brief):** `bank/fork-*` (both leaks +
  the footprint fix), `integ/pg-fork-arena`, `pr/parked-timer-unlink` (82 commits, fork-stack line),
  `bank/iouring-completion-fix` (live-agent-owned).
- **Superseded by an open PR - would be a competing duplicate:**
  - `pr/vfs-dentry-lock-order-v2` (`d6166ed3a`): its owned() rework **is** in #1502's `c7ab5929e` (rewritten,
    so not an ancestor, but the content landed). Redundant.
  - `pr/physio-per-iovec-v2` (`1b9b5add8`): **is an ancestor of** #1508's `75bb43bf6`. Redundant.
  - `pr/zfs-provider-manifest-v2`: differs from #1497's head only by deleting `modules/zfs/usr.manifest`
    (2 lines) - a delta to #1497, not a PR.
  - `pr/net-batch-wakeup-clean`: diverges from #1467 by 20 files / +597 lines of unrelated test material.
    Not a clean superset; do not file.
  - `pr/sec-ext4-readlink-v2` -> #1489 CLOSED, superseded by #1449 (which merges clean).
  - `pr/dentry-lock-order` (the `.local/worktrees/dentry` branch) - the #1502/#1503 working line.
- **Already filed and deliberately CLOSED** (do not refile): `pr/close-range` (#1436, #1417),
  `pr/epoll-pwait2` (#1427), `pr/elf-short-error` (#1404), `pr/signal-fills` (#1428), `pr/synch-wakeup-one`
  (#1403), `pr/numa-discovery` (#1437, #1418), `pr/kernel-fixes` (#1399), `pr/ext4-perf` (#1447 -> #1510),
  `pr/idle-spin-tunable` (#1476 -> #1501 -> #1511), `pr/sched-idle-spin-v2` (#1501 -> #1511).
- **Not upstream material:** `pr/stack-clean` (19 commits of NixOS/Codeberg/Forgejo CI local to our fork).
- **`pr/openzfs-runtime-datapool-fix`** already contained in an upstream ref.

**No branch is (standalone AND merge-clean AND validated AND unfiled).** Also note: **no PR on this repo has
any CI** ("no checks reported"), so nothing could be opened on the strength of a green build anyway.

=======================================================================
## TASK 8 - Local + LAN tidy
=======================================================================

### Worktrees: 11 + main = 12 entries. ALL DIRECTORIES EXIST. Nothing prunable, nothing removed.

| worktree | branch | a/b vs master | dirty | size | last mod | call |
|----------|--------|---------------|-------|------|----------|------|
| `~/ws/osv` | `wip/pg-rx-directwake` | 87a/24b | 118 | - | live | main, untouched |
| `.local/worktrees/dentry` | `pr/dentry-lock-order` | 4a/0b | 0 | 26M | 09-09 | **KEEP** - #1502/#1503 under live review |
| `.local/worktrees/fork-arena` | `integ/pg-fork-arena` | 41a/24b | 90 | 297M | 09-09 | keep (#1458-blocked line) |
| `.local/worktrees/forksym` | detached `5761ed02c` | 66a/24b | 2 | **2.3G** | 08-02 | keep; **largest by 7x**, detached HEAD - see note |
| `.local/worktrees/inotify` | `pr/inotify` | 1a/12b | 0 | 82M | 08-07 | keep (#1440, merges CLEAN) |
| `.local/worktrees/iouring` | `bank/iouring-completion-fix` | 172a/24b | 0 | 93M | 09-20 | **LIVE - DO NOT TOUCH** |
| `.local/worktrees/ipv6-port` | `pr/ipv6-forward-port` | 38a/30b | 0 | 83M | 07-31 | keep (#1442) |
| `.local/worktrees/signalfd` | `pr/signalfd` | 1a/2b | 0 | 82M | 08-13 | keep (#1439) |
| `/tmp/adapt-master` | `pr/sched-adaptive-idle-spin-master` | 1a/0b | 0 | 26M | 09-19 | **used this sweep for merge-tree** - keep |
| `/tmp/adapt-pr` | `pr/sched-adaptive-idle-spin` | 2a/0b | 0 | 26M | 09-19 | #1511's line - keep |
| `/tmp/fpwt` | `bank/fork-footprint-reduction` | 172a/24b | 0 | 33M | 09-19 | **DO NOT TOUCH per brief** |
| `/tmp/rxpool-wt` | `rxpool-fix` | 129a/24b | 2767 | 324K | 08-29 | **SPENT - safe to remove, see below** |

### `/tmp/rxpool-wt`: VERIFIED SPENT. Safe to remove, but NOT removed (your call).
The prior sweep flagged it "probably spent". Now verified against the no-unpushed-unique-commits rule:
- **Every commit is durable on a remote.** `git merge-base --is-ancestor 859210d54
  gh-fork/bank/fork-footprint-reduction-signed` = **true**, and the tip is contained in 10+ pushed gh-fork
  refs (`bank/fork-arena-real-reclaim`, `bank/fork-fd-reap-leak-reviewready`,
  `bank/fork-footprint-reduction{,-signed}`, `bank/sched-adaptive-idle-spin`, ...). **Nothing unique would be
  lost** - the branch ref itself also survives removal of the worktree.
- The 44 commits not in `wip/pg-rx-directwake` are all present in the banked fork branches.
- The directory is a **broken shell**: 324K, 43 files, and `git status` reports **2767 deletions** - the tree
  was gutted, not merely idle. Untouched since 08-29 (22 days).
- Removal reclaims ~324K, i.e. nothing. **Left in place** because there is zero pressure and removal has no
  benefit; say the word and it goes via `git worktree remove /tmp/rxpool-wt` (plain, no `--force`).

**Also flagged, not touched:** `.local/worktrees/forksym` is **2.3GB - 7x the next largest** and on a
**detached HEAD** (`5761ed02c`, 66a/24b) last modified 08-02. It is by far the biggest reclaim available in
the whole OSv footprint. A detached HEAD with 2 dirty paths is exactly the case the brief says not to guess
at, so **report only**: confirm `5761ed02c` is banked somewhere and it can go.

### /tmp OSv scratch: NOTHING REMOVED.
`df -h`: `/`, `/tmp`, `/home` are one 3.7T volume - **1.4T used, 2.1T available, 40%. Zero pressure.**
`/tmp`'s bulk is other projects (`solnix-*` 3x74G, `tui4-work` 48G, `tui2/tui3-build` 33G, `noxu-xbench` 11G,
`usb-*` 16G) - none of it OSv, none of it touched.
- **Brief-protected, not touched:** every `*iouring*`, `*scale*`, `*footprint*`, `*leak*`, `*cwwake*` entry
  (`/tmp/{apply_leak.py,leak.sql,p1_leak.sh,q7_leak.sh,leakhunt-{ip,patch},aio_leakrun.sh,n1_leak.log,
  rq[67]_leak.sh,leakteeth*.sh,clean_leaks.py,basescale.sh,i1scale.sh,patch_scale.py}`, etc.), plus
  `/tmp/fpwt`, `/tmp/rxpool-wt`, `/tmp/adapt-{master,pr}`.
- **NOT OURS, never touched:** libdb/opstats/ssi/gi/fa/wtail/gc-wt and recno/mvcc/getnext material; all
  solnix/larql/cosmic/catam/pgweave/tui/noxu files.
- **Certainly dead but reclaims ~0 bytes, so left alone:** 15 empty `/tmp/rt[bpq]-*` dirs (ZFS build scratch,
  09-07, all verified 0 entries), 22 empty `/tmp/pgbench-results-*` dirs, and empty
  `/tmp/{zfs-image,dlfork,dlfork-repro,bqscale,xml2hammer}`. **Correction to the prior sweep: `/tmp/hammerdb`
  (48 entries) and `/tmp/smokelzfs` (30 entries) are NOT empty** - they were listed as empty-dir candidates
  on 09-20; do not `rmdir` them on that basis.
- My own scratch (`/tmp/sw21-*.json`, `/tmp/sw21-*.txt`, `/tmp/sw21-dentry-*.cc`) is a few hundred KB, left
  in place.

### EC2 - REPORT ONLY (launched 0, terminated 0, tagged 0, ssh'd 0, 0 commands run on any box)
`AWS_PROFILE=hotdog`. Scanned us-east-1, us-east-2, us-west-1, us-west-2, eu-west-1.
- **`i-0f6bc380d2ff4c4d9`** (c5.9xlarge, Owner=agent-iouring, 14:06:47Z) and **`i-031500bbc802fdadb`**
  (m5d.metal, Owner=agent-iouring, 14:06:45Z), both `running` in us-east-2 - the live ZFS
  write-amplification root-cause run. **Not touched in any way.** Both still up ~3h into the run.
- NOT OSv, not mine, untouched (us-east-2): `undo-amtest-20260919`, `libdb-log`, `libdb-test`,
  `ra-pg19-20260920`, `pgweave-dev-20260920`, `undo-recnodef-20260919`, `solnix-tui4`.
- **0 instances in us-east-1, us-west-1, us-west-2, eu-west-1. 0 orphans. 0 `available` (unattached) volumes
  in all five regions. 0 `Owner=agent-maintsweep*` anywhere.** Clean.
- LAN hosts touched: **NONE**.

=======================================================================
## TASK 9 - Notes record refreshed
=======================================================================

### `notes/pg-campaign-record`: `5972d9241` -> see below. G-signed, fast-forward, BOTH mirrors.

Selection: from the 86 uncommitted `.local` paths, filtered to `*.md *.sh *.py *.txt *.json *.diff *.patch`,
**excluding `.local/worktrees`, `.local/pg18`, `.local/iouring`** and binaries -> 28 candidates. Then
content-compared each against `origin/notes/pg-campaign-record`: **19 were byte-identical** (already banked -
the 17 `zilab` probes plus `BLOCKED-WINS-2026-09-20.md`, `CAPTURE-STATUS-2026-09-20.md`,
`PR1502-REVIEW-ANALYSIS.md`, `WRITE-COMPLETION-BRIEF.md`) and were skipped. Net: **9 files** (1 changed,
8 new), including this report and the two new drafts.

`.local/iouring/*` **again EXCLUDED** - live-agent-owned, still a moving target while both boxes run. Those
files remain uncommitted and should be banked once the boxes are down.

Mechanics: `GIT_INDEX_FILE` + `read-tree` + `update-index` + `commit-tree -S`, so the main worktree's index
and dirty paths were never touched (verified after: same branch, same dirty count, 0 staged by me). Base is
the existing notes tip, whose parent is `upstream/master` and whose `apps` gitlink already matches
`upstream/master:apps` (`b2d53b348c`) - so no dangling-gitlink rework was needed and the pre-push hook had
nothing to reject. Pure fast-forward; `--force-with-lease=<old sha>` used as belt-and-braces, **no bare
`--force` anywhere**.

Leak posture: all 9 files `us-ascii`, no binaries; scanned for AWS keys, private keys, `ghp_` tokens, bearer
tokens, `password=` - **zero hits** (the one grep hit is the prior sweep's own prose *describing* the scan).
Per the standing note: these mirrors contain instance ids and private IPs, so **never paste notes into a
public PR body**.

=======================================================================
## CHANGES MADE THIS SWEEP
=======================================================================
1. `git fetch --all --prune` in `~/ws/osv` and `~/ws/osv/apps`.
2. Fetched PR heads to `refs/tmp/*` in `/tmp/adapt-master` (scratch worktree) for merge-tree analysis.
3. **Task 9: notes commit + fast-forward push of `notes/pg-campaign-record` to BOTH origin and gh-fork.**
4. Wrote `.local/maint-2026-09-21/PR1502-COMMENT-GAP.md` + `pr-1502-comment-fixes.diff` (drafts) and this report.

**NOT done, by rule or pending your judgment:**
- Nothing posted to any PR. No nudge on #1439/#1464/#1458. Neither open question answered for him.
- **The #1502 comment patch was NOT pushed** (live review + invisible-pending-review risk).
- No rebase, no PR-branch force-push, no merge, no PR opened or body edited, no dependency bumped.
- No worktree removed (`/tmp/rxpool-wt` verified spent, `forksym` 2.3GB flagged - both your call).
- No `/tmp` entry removed. No `git add -A`. No `.gitignore` touched. No EC2 action. No LAN host touched.

=======================================================================
## WHAT I WOULD DO NEXT, IN ORDER
=======================================================================
A. **Decide the #1502 comment patch** (fold into the next rewrite vs amend now). It is the only thing on the
   board where our public claim and our tree currently disagree, and he is the one person who will notice.
B. **Wait on his two answers.** Both are genuine scope calls; the code for either branch is ready.
C. **#1458 is still the keystone** - three validated fixes, 0 reactions, no reply. Nothing else unblocks them.
D. **#1464 is one click** whenever the merger returns; `wkozaczuk`'s public feed is completely empty.
E. When #1503 is reworked, apply the same comment pass - it inherits all four claims.
F. Bank `.local/iouring/*` once the write-amplification run finishes.
