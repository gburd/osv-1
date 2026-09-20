# OSv upstreaming maintenance/tidy sweep - 2026-09-19 (late)

Follow-on to `.local/maint-2026-09-18-sweep.md`. Every item re-verified TODAY (2026-09-20 ~01:30-02:10 UTC).
Read-heavy; changes limited to fetches, one factual PR-body correction on my own PR, and three provably
dead /tmp entries.

DID NOT TOUCH (per brief):
- LIVE EC2 i-0295dadedf57f4f0c (c5.9xlarge) + i-00b52ea02ffc05430 (m5d.metal), both Owner=agent-scale,
  launched 01:27 UTC = the HammerDB VU32-192 scaling run. No ssh, no terminate, no tag change. EC2 section
  is REPORT-ONLY.
- Branches/files: bank/fork-footprint-reduction*, bank/fork-arena-real-reclaim, bank/fork-fd-reap-leak*,
  bench/leakhunt, core/fork_arena.cc, core/sched.cc, PR #1458, PR #1511 code, .local/{scale,footprint2,
  cwwake,gates,leak2}/*. The main worktree's 396 staged/modified paths (the live .local/wakelat + scale
  work) were left exactly as found.

Environment: SSH agent /run/user/1000/wezterm/agent.3913155. AWS: `lava` is DEAD (InvalidClientTokenId);
`hotdog` (585335547908) is the live account, quota L-1216C47A now **1152** (granted).

## HEADLINE DELTA vs the 2026-09-18 sweep
- upstream/master STILL **0e34e4dc2** (unmoved since 2026-08-17). No new conflicts anywhere.
- **0 new reviewer comments**, repo-wide. Newest non-gburd, non-bot touch is still 2026-08-03.
- **#1511 has 0 comments / 0 reviews / 0 inline** - awaiting first review. Merge-tree CLEAN, MERGEABLE.
- **#1458 comment 5718101962 (S1..S8) still has NO reply and NO reactions.** All four #1458 comments are mine.
- #1501 is CLOSED (2026-09-19T11:33:50Z) as superseded by #1511 - confirmed.
- NEW, and the one thing I changed on a PR: #1511's body said "#1501 **will be** closed as superseded";
  #1501 is already closed. Corrected to "is now closed" (trivially-factual, my own PR). Nothing else edited.
- NEW FINDING (Task 7): exactly ONE standalone, merge-clean, unfiled, buildable candidate exists -
  `bench/syncwrite-mt` (the instrument behind #1511's numbers). Drafted + flagged, NOT opened (see Task 7).
- Deps unchanged: OpenZFS 2.4.3 pinned, 2.4.4 correctly prepared in #1488; lwext4 pin ready in #1500.
- Tidy: 14 worktrees, ALL directories present, 0 prunable. Removed 3 provably-dead /tmp entries.

=======================================================================
## TASK 1 - Reviewer comments on all 56 open gburd PRs
=======================================================================

Scanned all 56 open PRs three ways (issue-comments, pulls inline-comments, pulls reviews), filtering
gburd + bots. 37 human reviewer events total, all historical.

### FINDING: ZERO new reviewer activity since the 2026-09-18 sweep. Nothing to reply to, nothing posted.

Newest non-gburd, non-bot activity repo-wide, UNCHANGED:
- issue-comments: @nyh #1455 2026-08-03T12:38:44Z
- inline review comments: @wkozaczuk #1455 2026-08-03T14:01:22Z
- reviews: @nyh APPROVED #1464 2026-08-03T14:29:05Z

Maintainer presence check (wider than PR comments, to be fair to them): @wkozaczuk's last repo activity
of any kind is 2026-08-17T14:54:20Z on #1423 ("Looks good. I have tested it. Please un-draft it."), and he
merged #1473 on 2026-08-17T01:47:23Z. So **@wkozaczuk, not @nyh, is the active merger** - and he has been
silent for 33 days, since the #1423 merge. That merge IS 0e34e4dc2, i.e. master stopped moving on the same
day he went quiet. Worth knowing: the "maintainer offline since 2026-08-03" line in the prior state files
is about nyh; the merger who was actually landing our work went quiet 2026-08-17.

### #1458 S1..S8 proposal (explicit ask)
Comment **5718101962**: author gburd, created == updated 2026-09-17T16:51:49Z (never edited),
**reactions total = 0**, **no reply**. All four #1458 issue-comments are gburd's (08-15, 08-28, 09-11, 09-17).
The keystone composition decision remains unanswered.

### #1511 first review (explicit ask)
`isDraft=false, mergeable=MERGEABLE, reviewDecision=(none), comments=0, reviews=0, inline comments=0`,
created 2026-09-19T11:33:28Z. Awaiting first review. merge-tree vs upstream/master = CLEAN.

### Re-checks (explicit ask)
- **#1439 signalfd - STILL STALE.** CHANGES_REQUESTED, MERGEABLE, non-draft. All 8 review threads
  `isResolved=true`, every one lastBy=@gburd (last 2026-08-01T17:09:01Z). Nothing substantive outstanding;
  only a maintainer can clear the flag. Unchanged.
- **#1464 disperse - APPROVED, CONFIRMED, and now also `mergeStateStatus=CLEAN`.** 6 review threads
  unresolved but each lastBy=@gburd (last 2026-09-09T14:06:28Z). It is literally one merge click.

No reply drafted (nothing to reply to). No nudge posted (do-not-nudge standing rule).

=======================================================================
## TASK 2 - Upstream-filed dependency issues/PRs
=======================================================================

### FINDING: still exactly one outstanding external filing, still dormant. Null result.

- **gkostka/lwext4 #100** (ext4_ext_check OOB read): OPEN, **0 comments**,
  `created_at == updated_at == 2026-07-14T14:24:21Z` - byte-for-byte unchanged across eight checks now.
  Upstream lwext4 last pushed 2024-03-22; no reply expected. Our fix ships via the osvunikernel/lwext4
  fork OSv builds from, and as OSv PR #1449. Non-blocking. Correct action: leave it open as the
  good-citizen report. **No action available.**
- Full `author:gburd -repo:cloudius-systems/osv` issue+PR search re-run: the only OSv-relevant EXTERNAL
  filing is lwext4 #100. Everything else returned is other projects (berkeleydb/libdb, chrishayuk/larql,
  malisper/pgrust, RyanCodrai/turbovec, qpdb/mentat, ...) - not OSv deps.
- openzfs/zfs, qemu, musl, acpica, firecracker: **0** filings authored by gburd. Unchanged.

### Our own OSv-repo issues (for completeness, these are not "upstream-filed deps")
- **#1474** "OpenZFS: five filesystem tests fail under conf_zfs=openzfs": OPEN, 0 comments, unchanged
  since 2026-08-17. Verified the two things #1423's review asked for ARE on master: `tests/misc-zfs-db-sim.cc`
  exists (renamed from tst-) and all five gaps are documented in
  `modules/open_zfs/FINDINGS-osv-openzfs.md` lines 130-134. So #1474 is correctly a tracked known-gap
  issue, not an unmet review request. Nothing owed.
- #541 (2014, pre-existing): stale, not ours to act on.

=======================================================================
## TASK 3 - Dependency currency (all verified TODAY, nothing bumped)
=======================================================================

| dep | pin on upstream/master | newest upstream | gap | risk | prepared? |
|---|---|---|---|---|---|
| OpenZFS submodule | `83020cf8` = zfs-2.4.3 (.gitmodules branch=zfs-2.4.3) | **zfs-2.4.4** (peels to `71a9f957`) | 1 point release | LOW | **YES - #1488** |
| lwext4 (build-time clone) | UNPINNED: `git clone --depth 1 .../osvunikernel/lwext4.git` | fork HEAD `6f6d8f7c` | reproducibility hazard, not a version gap | LOW | **YES - #1500** |
| apps submodule | `b2d53b34` | cloudius/osv-apps master `b2d53b34` | **CURRENT** | - | n/a |
| kbuild | `9f1d27a8` | remote HEAD `9f1d27a8` | **CURRENT** | - | n/a |
| external/x64/acpica | `3e45e0f2` | cloudius fork HEAD `3e45e0f2` | **CURRENT vs the fork** (fork itself ~13y behind ACPICA proper, by design) | - | n/a |
| swagger-ui | `5d7010b9` | fork HEAD `5d7010b9` | **CURRENT** | - | n/a |
| osv-gui | `c93b2f5c` | fork HEAD `c93b2f5c` | **CURRENT** | - | n/a |
| musl_1.2.1 | `73cc775b` = musl "release 1.2.1" (2020-08-04) | osvunikernel fork HEAD `a5aff197` (2020-09-17), 49 commits ahead; musl proper is at v1.2.6 | deliberate release-tag pin | LOW (touching it is a libc-wide change, NOT a maintenance bump) | no, and correctly so |
| musl_0.9.12 | `372a948b` | cloudius fork HEAD `00733dd1` | deliberate ancient pin (legacy path) | LOW | no |

- **#1488 verified correct**: its `modules/open_zfs/openzfs` gitlink is `71a9f9578616a90c...` which is
  EXACTLY the dereferenced `zfs-2.4.4` tag, and it also updates `.gitmodules` branch to `zfs-2.4.4`
  (both halves, not just the gitlink). mergeable, non-draft, merge-tree CLEAN.
- **#1500 verified correct**: replaces the floating `clone --depth 1` with
  `lwext4_commit?=6f6d8f7c509da696e71e80cc5a59abfc48e4971b` + `git checkout --detach`, overridable for
  testing. Merging is a no-op on bits and removes the irreproducibility. mergeable, merge-tree CLEAN.
- No zfs-2.4.5 and no zfs-2.5.x exist (zfs-2.4.99 is a dev tag, not a release) - re-verified via ls-remote.

### FINDING: OpenZFS is one point release behind and the bump is already prepared and clean in #1488;
### lwext4's only issue is the unpinned clone and that is prepared in #1500. Everything else is current
### against the fork it pins. **Bumped NOTHING.**

=======================================================================
## TASK 4 - Remaining plan: DONE / IN-PROGRESS / NOT-STARTED / BLOCKED
=======================================================================

### DONE (validated)
- **M1 scaling arc, honestly characterized end to end.** VU8/16 OSv FASTER than Linux (1.17x / 1.29x).
  VU32 idle->wake tail FIXED (#1511). VU64 wall SOLVED.
- **The VU64 wall is SOLVED and was NOT a wake bug.** Root cause = the fork per-backend footprint churn
  bug (overflow-commit = 99% of per-backend memory: ~245 of 247 MB). Six wake-path A/Bs had chased a
  symptom; the OOM console named it. The wakeup-deficit theory for VU64 is RETIRED.
- **The footprint fix LANDED (banked+validated):** per-backend private **247 MB -> 10.0 MB** (24.7x,
  inside Linux's 5-15 MB band); overflow live 17.5 GB -> 283 MB (63x); memfree +17.5 GB.
  **MAX BACKENDS ~74 -> 576, and it stopped at max_connections=600 with 42.4 GB STILL FREE, so 576 is a
  FLOOR, not a ceiling.** The practical "~74 backends isn't going to work" blocker is GONE.
  Branch: bank/fork-footprint-reduction-signed @ 1480fbee1 (5 commits, all G-signed).
- **The env/getenv scare is CLEARED** (`.local/ENV-AUDIT-RESULT.md`): putenv DOES run; the missing log
  line was only a verbose-gated `debugf`. **No campaign result is invalidated.** Only early-boot consumers
  (before loader.cc:818) are affected, i.e. the fork_arena probe - which is exactly what looked broken.
  Bonus correction that makes our numbers MORE conservative: OSV_ZFS_ARC_MAX was absent from the a2a base,
  so OSv ran a ~2 GB ARC against Linux's matched cap -> the a2a ratios understate OSv, not overstate it.
- Two leaks: **leak #1** (fd/gfdt EMFILE, 400-round A/B) and **leak #2** (fork-arena memory, 5 gates /
  26,181 backends) - engineering COMPLETE + validated, banked.
- 11 banked generic fixes all open + merge-clean (#1502/#1503/#1504/#1505/#1506/#1507/#1508/#1509/#1472/
  #1480/#1484). #1478 native-ZFS runtime data pool open + clean (retires 4a as a strict subset).
- #1511 (adaptive idle-spin) is OPEN upstream, direct-to-master, merge-clean, superseding #1501.

### IN-PROGRESS (other agents own these - untouched)
- **VU32-192 HammerDB scaling re-test WITH the footprint fix** - LIVE on i-0295dadedf57f4f0c +
  i-00b52ea02ffc05430 (Owner=agent-scale). This is the real "does OSv scale like Linux now that hundreds
  of backends fit" answer.
- **The VU32 median gap (~0.65x Linux) - a DISTINCT, still-unexplained throughput factor.** Cleanly
  separated from the footprint WITH a mechanism, not just a null: the footprint A/B at 32 clients was
  +0.4% (noise) AND `ovflive_MB=0` in BOTH arms, i.e. the overflow path is never even entered at VU32, so
  there was no memory pressure to relieve. Not a wake bug, not memory pressure. Under investigation in the
  live run.

### BLOCKED
- **On the maintainer (the merger, @wkozaczuk, silent since 2026-08-17):** every merge. Queue as before:
  #1464 (APPROVED + mergeStateStatus CLEAN) then #1502/#1503/#1504; then #1488 (OpenZFS 2.4.4) + #1500
  (lwext4 pin); then #1478 + #1449; then the ready standalone family (#1511, #1472, #1477, #1479-#1486,
  #1490-#1499, #1505-#1509 ...). Plus clearing #1439's stale CHANGES_REQUESTED.
- **On the #1455/#1456 fork-composition keystone:** the S1..S8 proposal (#1458 comment 5718101962) has no
  reply. This gates THREE validated wins' landing path - leak #1 (S5), leak #2 (S8), and now the footprint
  fix (S8 area) - because all three strictly stack on the unmerged fork generation.

### NOT STARTED
- **M2 / PGXN** (every PGXN extension identical OSv-vs-Linux: pg_stat_statements, pgvector, PostGIS).
  Still NOT STARTED. It is the natural next milestone once the scaling re-test lands, and it exercises the
  same dlopen/ELF surface the fork/COW fixes repaired.
- #1510 ext4 read-ahead: DRAFT, needs an ext4 re-measure on current master (needs EC2).
- NUMA family rebase (#1438/#1441/#1445) onto master's SRAT/SLIT layer (a92c44f9b).
- 4b RDSEED: fold into #1492 after its review settles (do NOT open a competing PR).
- Pre-PR cleanup of the footprint branch: strip probe-only bits (g_ovf_recycled, overflow_stats(), probe
  comment blocks, pre-existing leak_probe_stats cruft) but **KEEP ovf_mapped** - it looks like a probe
  counter but is the fix's load-bearing per-AS window cursor. Needs a build check.
- The BEFORE-arm **stack-overflow** signature at high backend count (crash with 29 GB free, NOT the
  documented OOM) - possibly a distinct bug. Unexamined.

=======================================================================
## TASK 5 - Draft-PR currency vs upstream
=======================================================================

- **upstream/master is STILL 0e34e4dc2** (fetched all remotes; no movement since 2026-08-17).
  local `master`, `gh-fork/master`, `origin/master` ALL at 0e34e4dc2.
- Because upstream is unmoved, **this sweep introduces zero new conflicts.**

merge-tree --write-tree --messages over all 56 open PR heads vs upstream/master:
**48 CLEAN / 8 CONFLICTING - byte-identical to the last three sweeps.**

Conflicting, with the actual conflicted paths:
- **#1440** (inotify) and **#1449** (ext4 heap overflow): conflict ONLY in `modules/tests/Makefile`.
  Trivial base drift; a rebase re-appends the test line. Not substantive.
- **#1438 / #1441 / #1445** (NUMA family): SUBSTANTIVE. add/add in `core/numa.cc` + `include/osv/numa.hh`
  (+ `modules/tests/Makefile`; + `tests/tst-numa.cc` for #1441). Master gained the SRAT/SLIT layer
  (a92c44f9b) AFTER these branched. Needs a real rebase onto the new layer.
- **#1456 / #1475** (fork COW stack): `libc/signal.cc` + `modules/tests/Makefile`. Fork-stack dependent,
  blocked on the composition decision. DO NOT TOUCH.
- **#1458** (tracking, DO-NOT-MERGE): .gitignore, .gitmodules, Makefile, apps submodule,
  drivers/virtio-balloon.cc, exported_symbols/... - expected for the tracking unit.

No draft needs a refresh purely for staleness: upstream did not move, so every draft is exactly as
current as it was. The refresh debts are the pre-existing ones (NUMA rebase; #1510's ext4 re-measure).
Temp `refs/prheads/*` used for the scan were all deleted (0 remain). **No rebase, no force-push.**

=======================================================================
## TASK 6 - Sync local osv + osv-apps
=======================================================================

### osv (~/ws/osv)
`git fetch --all --prune` (origin=codeberg, upstream=cloudius, gh-fork=github/gburd/osv-1). Read-only.
- upstream/master 0e34e4dc2 UNMOVED. **master == gh-fork/master == origin/master == upstream/master.**
  Fork mirrors are NOT behind; nothing to push.
- Working branch = wip/pg-rx-directwake (86 ahead / 24 behind upstream) - the live work. Untouched.

### osv-apps (checkout at ~/ws/osv/apps)
`git fetch --all --prune` across all five remotes (origin, codeberg, gh-upstream, gh-fork, cloudius).
- checkout HEAD = **3f93f43** on branch pr/phony-build-and-io-method-comment.
- cloudius/master = gh-upstream/master = **b2d53b34** (unmoved).
- divergence: **2 ahead / 655 behind** cloudius/master (unchanged). Both ahead commits touch only
  postgres18-musl (seed_copy rofs-modes fix + the shadowed-build-target/io_method note) -> clean rebase later.
- **osv-apps #73 (postgres18-musl demo): CURRENT.** OPEN, DRAFT (held on the OSv fork/COW landing),
  `headRefOid = 3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3` = **EXACTLY our checkout pin**. Verified.
- NEW detail worth noting: the osv-apps FORK mirrors (codeberg/gh-fork/origin `master` = `0b98404`) are
  **1 commit behind** cloudius/master, and `0b98404` IS an ancestor of `b2d53b34`, so they are plain
  fast-forwardable (no force-push). Report only, did not push - the brief limits me to fetch+report here.
- Also open: osv-apps **#71** (ec2-audit app, non-draft, MERGEABLE, no review since 2026-07-02). Nothing owed.

### FINDING: everything current. OSv master + both fork mirrors at 0e34e4dc2; the apps submodule pin on
### master (b2d53b34) equals cloudius/osv-apps master; our apps checkout equals #73's exact head. Fetch +
### report only; no merge, no rebase, no push.

=======================================================================
## TASK 7 - PRs for finished + unblocked features
=======================================================================

### FINDING: exactly ONE candidate qualifies. I DRAFTED it and did NOT open it (one judgment call I will
### not make for you). Everything else DONE+validated is either already open or fork-stack-blocked.

To find candidates honestly I indexed `git patch-id --stable` for every commit on all 56 open PR heads
plus the last 500 commits of upstream/master (690 patch-ids), then checked every unfiled local/gh-fork
branch against that index. That catches "already filed under a different SHA" and "already landed", which
a name comparison misses.

**THE CANDIDATE: `gh-fork/bench/syncwrite-mt` @ 1cdbe3541** - ONE commit, and its parent IS
upstream/master 0e34e4dc2 exactly. Touches ONE file, `scripts/bench/zfs-bench.c`, whose base blob is
byte-identical to master's. merge-tree CLEAN. G-signed. No em-dashes. No perf claim in the message. It
is the instrument that produced #1511's published table (27200 -> 44841 op/s, wake2ent 137 -> 78us,
p99 3484 -> 2118us), so filing it makes #1511 reproducible by a reviewer.
I ran the project's OWN gate locally to validate it rather than asserting it: the exact
`scripts/bench/rebuild-bench.sh` compile line (`gcc -std=gnu11 -O2 -fPIC -shared -D__OSV__ -D_GNU_SOURCE
... -lm`) builds it **rc=0**, and `nm -D | grep -E 'GLIBCXX|CXXABI|__isoc23'` is **EMPTY** (the hard gate
for loadability in OSv).
**Why I did not open it:** whether the project wants another bench workload upstreamed is maintainer
taste, not a correctness fact, and the merger has been silent 33 days - so opening buys no velocity and
adds queue noise. Body + exact open command drafted:
`.local/maint-2026-09-19/DRAFT-pr-syncwrite-bench.md`. **Flagged for you (item D).**

Everything else, with the reason it is NOT openable (each checked, not assumed):
- **The footprint fix / leak #1 / leak #2** - all three stack on the unmerged fork generation; blocked on
  the #1458 composition decision. Brief-named off-limits. NOT opened.
- **`/tmp/adapt-pr` (pr/sched-adaptive-idle-spin, 2 commits)** - the fork-era precursor carrying BOTH the
  old fixed OSV_IDLE_SPIN commit and the adaptive one. #1511 is the clean single-commit master version of
  this; opening it would be a competing duplicate. Correctly superseded.
- **`pr/close-range`** - its close_range commit ALREADY LANDED as upstream 1b809fc80; per-file blob compare
  shows `fs/vfs/main.cc` close_range hunk, both syscall.h, unistd.h, linux.cc and tst-close-range.cc are
  IDENTICAL to master. The residual diff is master's own later drift (zfs mnt_opts, the setrlimit
  tracepoint, the conf_zfs test-Makefile block) coming from its 2026-08-06 base. Nothing to file; branch is
  spent.
- **`pr/numa-discovery`** - `core/numa.cc`, `include/osv/numa.hh`, `tests/tst-numa.cc` blobs are IDENTICAL
  to master (landed as a92c44f9b + af96db0f7; the second commit is patch-id-identical to master's). Spent.
- **`pr/dentry-lock-order`** - all three functional commits are patch-id-identical to #1502/#1503 content;
  only the test file differs slightly. Already filed. Nothing new.
- **`pr/inotify`** (61468db1c) vs #1440's head (e18e81cc2): the ONLY difference is 2 lines of
  `modules/tests/Makefile`. #1440's head is the newer one. Local branch is stale-but-harmless, not a
  missing PR.
- **`.local/worktrees/scrub-aarch64` (detached 5d1215562)** - checked commit by commit: 2 of its top 3 are
  patch-id-identical to #1459's commits, the rest belong to #1458's ZFS stack. Its top commit
  ("aarch64: raise ARM generic-timer frequency ceiling to 2GHz") shows as UNFILED by patch-id, **but the
  CONTENT is in #1459** - #1459 carries the same 1GHz->2GHz change in `arch/aarch64/arm-clock.cc` with a
  vendor-neutralized comment (the ROADMAP records exactly that genericization + force-with-lease). So it
  is filed, just re-worded. **Nothing unfiled here.**
- **`.local/worktrees/forksym` (detached 5761ed02c, 66 ahead)** - every commit checked is in #1458's
  tracking stack. Fork-stack. NOT openable.
- **`gh-fork/wip/fork-posix-fdtable{,-v2..v5,-final}`** (6 near-identical 6-8 commit variants) - all are
  older iterations of the #1455 fork base. Superseded, not candidates.
- 4a native-ZFS: SUPERSEDED by open #1478 (strict subset + non-functional alone). **Not re-opened**, per brief.
- 4b RDSEED: folds into #1492 after review; do not open a competitor.
- NUMA family: a rebase, not a new PR.

### Opened: NOTHING. Drafted: 1 (syncwrite bench). Nothing unvalidated or fork-stacked was touched.

=======================================================================
## TASK 8 - Local + LAN tidy
=======================================================================

### Worktrees (14 = main + 13 linked)
**ALL 14 directories present on disk; `git worktree prune -v` = no-op (0 prunable).** Ran it anyway; it
removed nothing, which is the correct outcome. All clean except the main tree (the live work, 396 paths)
and `.local/worktrees/forksym` (2 dirty submodule gitlinks: kbuild, musl_1.2.1 - harmless).

**None are merged into upstream/master**, so none is auto-safe to delete. Three are SPENT (their content
landed or is filed elsewhere) - **your call, I removed nothing:**

| worktree | branch | status | my read |
|---|---|---|---|
| `.local/worktrees/close-range` (82M) | pr/close-range | content LANDED as upstream 1b809fc80 | **prunable** |
| `.local/worktrees/numa` (82M) | pr/numa-discovery | content LANDED as a92c44f9b + af96db0f7 | **prunable** |
| `.local/worktrees/scrub-aarch64` (26M) | detached 5d1215562 | content filed in #1459 / #1458 | **prunable** (detached = no branch to lose) |
| `.local/worktrees/dentry` (26M) | pr/dentry-lock-order | filed as #1502/#1503, banked on gh-fork | prunable-ish; branch is the only copy of the test variant |
| `.local/worktrees/inotify` (82M) | pr/inotify | 2 lines behind #1440's head | keep or refresh |
| `.local/worktrees/signalfd` (82M) | pr/signalfd | == #1439 head, banked on gh-fork | KEEP (live PR) |
| `.local/worktrees/ipv6-port` (83M) | pr/ipv6-forward-port | == #1442 head, banked 4 places | KEEP (live PR) |
| `.local/worktrees/fork-arena` (297M) | integ/pg-fork-arena | LEAK WORK | KEEP - off-limits |
| `.local/worktrees/forksym` (2.3G) | detached 5761ed02c | #1458 fork stack, **2.3 GB** (largest) | KEEP (off-limits) but it is the one worth reclaiming later |
| `/tmp/adapt-master` (26M) | pr/sched-adaptive-idle-spin-master | == **#1511 head** | KEEP (live PR) |
| `/tmp/adapt-pr` (26M) | pr/sched-adaptive-idle-spin | superseded by #1511 | prunable, other agent's area |
| `/tmp/fpwt` (33M) | bank/fork-footprint-reduction | THE FOOTPRINT FIX | KEEP - off-limits |
| `/tmp/rxpool-wt` (324K) | rxpool-fix | ancestor of 30 gh-fork branches | KEEP (load-bearing base) |

### /tmp
`df -h`: / and /tmp are one 3.7T fs, **41% used, 2.1T free. No space pressure.**
The big consumers are NOT OSv (solnix-dixi/b2 74G each, noxu-xbench 27G, hib 27G, tui2-build 19G) - other
projects, untouched.

**Deleted (3 items, each verified dead, total reclaim ~0):**
- `/tmp/osvarm` - empty dir, 2026-09-07, `rmdir` (fails if not empty = the safety proof).
- `/tmp/osv-wakepull-results` - empty dir, 2026-08-29, `rmdir`.
- `/tmp/lwext4-hdrs` - symlink whose target
  (`.local/worktrees/sec-ext4-readlink/modules/lwext4/upstream/lwext4`) no longer exists. Dangling by
  definition. Removed the link only.
Also removed my own sweep scratch (mt1511.txt, pidmap.json, the two zfs-bench build artifacts).

**Deliberately LEFT:**
- Every `/tmp/*scale*`, `*footprint*` (`/tmp/fpwt`), `*leak*` (p1_leak.sh, q7_leak.sh, aio_leakrun.sh,
  leakhunt-*), `*gate*`, `*cwwake*`, `/tmp/adapt-*` - live-agent territory per brief.
- The small OSv helper scripts (osv_boot.sh, osvrun*.sh, osv_zpool.sh, osv_disk.sh, osv_prep.sh,
  osv_image*.sh, ssh_osv.sh, lwbpipe-osv-*.sh, osv-hotdog.pub, osv-lava.pub, my_adaptive_sched.cc/hh,
  adaptive-*msg*.txt, forkgen.txt, fork-668e59e.tar.gz): all tiny, reclaim nothing, and with a live
  scaling run in flight I am not certain they are dead. Zero pressure -> leave.
- `/tmp/p0-1447-musl` -> resolves to ~/ws/osv/musl_1.2.1: **live symlink, kept.**
- NOT OURS, never touched: opstats/ssi/gi/fa/wtail/gc-wt, recno/mvcc/getnext scripts, libdb/solnix/larql/
  cosmic/catam/pgweave files.

### EC2 - REPORT ONLY (launched 0, terminated 0, tagged 0)
`lava` is DEAD (InvalidClientTokenId). Live account = **hotdog / 585335547908**; quota L-1216C47A =
**1152** (the request was granted - metal now launches).
Scanned us-east-1, us-east-2, us-west-1, us-west-2, eu-west-1:
- **i-0295dadedf57f4f0c (c5.9xlarge, Owner=agent-scale, 01:27:46Z)** and
  **i-00b52ea02ffc05430 (m5d.metal, Owner=agent-scale, 01:27:40Z)** - the LIVE scaling run. Brief-named
  off-limits. **Not touched, not ssh'd, not tagged.**
- NOT OSv, not mine, untouched: libdb-cliff, libdb-p3, undo-amtest, undo-recnodef, ra-subquery,
  pgweave-dev, solnix-tui3, catam-restore (us-east-1).
- **Owner=agent-maintsweep* instances: 0.** Nothing of mine anywhere.
- **0 non-in-use (orphan) volumes in every region scanned.** 0 orphan instances. Clean.
- LAN hosts touched: NONE.

=======================================================================
## CHANGES MADE THIS SWEEP (safe + clearly correct only)
=======================================================================
1. `git fetch --all --prune` in ~/ws/osv and ~/ws/osv/apps (read-only sync).
2. Fetched open PR heads to `refs/prheads/*` for merge-tree/patch-id analysis, then **deleted all of them**
   (verified 0 remain). No persistent local refs created, no branches created.
3. **#1511 PR body: "#1501 will be closed as superseded" -> "#1501 is now closed as superseded."**
   My own PR; #1501 closed 2026-09-19T11:33:50Z; trivially-factual. Nothing else in the body changed.
4. Deleted 3 provably-dead /tmp entries (2 empty dirs via `rmdir`, 1 dangling symlink) + my own scratch.
5. `git worktree prune -v` (no-op, 0 prunable).
6. Wrote this report + `.local/maint-2026-09-19/DRAFT-pr-syncwrite-bench.md`.

NOT done (by rule or needing your judgment):
- No reviewer reply posted (there is nothing to reply to) and no nudge.
- No PR opened (the one candidate is drafted + flagged).
- No rebase, no force-push, no merge, no dependency bump.
- No worktree removed (3 spent ones reported for your decision).
- No EC2 launch/terminate/tag; did not touch either agent-scale box.
- Did not touch the in-flight fork/footprint/leak/scale branches, files, or the main working tree.

=======================================================================
## ITEMS NEEDING YOUR JUDGMENT
=======================================================================
A. **#1455/#1456 fork composition = THE keystone.** The S1..S8 proposal (#1458 comment 5718101962) has no
   reply after 3 days. It now gates THREE validated wins, not two: leak #1, leak #2, AND the footprint fix
   (247 MB -> 10 MB, 74 -> 576+ backends). Highest-leverage unblock in the program.
B. **The merger is @wkozaczuk and he went quiet 2026-08-17** (not 2026-08-03, which is nyh's last touch) -
   the same day he merged #1423 = 0e34e4dc2, which is why master has not moved. If you ever decide to
   nudge, he is the address, and #1464 (APPROVED + CLEAN) is the one-click ask.
C. **#1439:** clear the stale CHANGES_REQUESTED (all 8 threads resolved, answered through 2026-08-01) -
   maintainer-only action.
D. **Open the syncwrite bench PR?** Standalone, merge-clean, G-signed, locally build-gated, and it makes
   #1511's measurements reproducible. Body ready in `.local/maint-2026-09-19/DRAFT-pr-syncwrite-bench.md`.
   One word and I file it.
E. **Prune 3 spent worktrees?** close-range + numa (content landed upstream) + scrub-aarch64 (filed in
   #1459). ~190 MB. Also `/tmp/adapt-pr` (superseded by #1511) if its owner agrees. Say go and I do it.
F. **The 2.3 GB `forksym` worktree** is by far the biggest local OSv scratch. Off-limits now (fork stack),
   but it is the reclaim target once the fork series lands.
G. **The BEFORE-arm stack-overflow signature** (crash with 29 GB free, not the OOM) from the footprint run
   may be a SEPARATE bug. Unexamined. Worth a look.
H. **#1438/#1441/#1445 NUMA family** need a real rebase onto master's SRAT/SLIT (a92c44f9b).
I. **4b RDSEED -> fold into #1492** after its review settles.
J. **After the live scaling re-test lands:** if OSv scales VU64-192, M1 is complete and **M2/PGXN** is the
   next milestone (still NOT STARTED). If a new wall appears it gets named and chased like the others.

=======================================================================
## PROGRAM STATE
=======================================================================
Strong position, one live thread, zero external motion. The big news is all ours and all good: the VU64
wall is SOLVED (it was the footprint churn bug, not a wake bug), the footprint fix takes a backend from
247 MB to 10 MB and the practical ceiling from ~74 to 576-with-42GB-free, and the env audit cleared the
whole campaign without invalidating a single result (and showed the a2a ratios were conservative for OSv,
not inflated). #1511 is upstream awaiting first review. The remaining unknown is honest and narrow: the
VU32 median gap is a distinct throughput factor, ruled out as footprint pressure WITH a mechanism, now
under investigation in the live VU32-192 run.
Externally, nothing moved at all: upstream/master unmoved for 34 days, zero new reviewer comments, no
reply to the composition proposal, no activity from the merger in 33 days, deps stable, 0 EC2 orphans.
Three validated wins sit behind one maintainer decision. Nothing else safe was left to change.
