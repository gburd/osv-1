# Maintenance PR Actions

Date: 2026-08-26
Operator: automated maintenance sweep (git/PR work only, no heavy builds)
Repo: /home/gburd/ws/osv (branch wip/pg-rx-directwake, working tree untouched)

All work was done in `/tmp` throwaway worktrees/clones, all now removed. The
pre-existing `.local/worktrees/*` and `/tmp/rxpool-wt` worktrees were NOT
created or touched by this sweep.

---

## 1. Crucible PR #1424 — un-BLOCK (DONE)

URL: https://github.com/cloudius-systems/osv/pull/1424

- Verified all three blockers are MERGED to master:
  - #1398 (pagecache/vfs ZFS page-cache bridge) merged 2026-07-12
  - #1400 (block TRIM/DISCARD + virtio-blk multiqueue) merged 2026-07-16
  - #1423 (selectable in-kernel OpenZFS) merged 2026-08-17
- PR was already NOT a GitHub draft (`isDraft: false`) and `mergeable: MERGEABLE`.
- Rebase check (throwaway worktree `/tmp/mnt-crucible` on `gh-fork/pr/crucible-draft`):
  the branch is ALREADY based on the current upstream/master tip
  (merge-base == upstream/master == 0e34e4dc2). It is a single clean commit
  (`cdb02c912 drivers: add Crucible distributed block storage driver`), signed
  (`%G? == G`, Good signature, Greg Burd). `git rebase upstream/master` was a
  no-op ("HEAD is up to date"). **No rebase/force-push needed.**
- **Body updated** (`gh pr edit 1424 --body-file`): removed the
  `[!WARNING] DRAFT / BLOCKED` block and the "please do not review the diff"
  language; replaced with a "What this delivers / Validation / Known limitation"
  body noting the three dependencies have merged and the branch is now reduced to
  just the Crucible driver. Leak-scanned clean before applying.
- Title left as-is (already had no BLOCKED/DRAFT text):
  "drivers: add Crucible distributed block storage driver".
- **Not re-marked ready** because it was never a draft; nothing to do there.
- **Comment posted** summarizing the un-block:
  https://github.com/cloudius-systems/osv/pull/1424#issuecomment-5421655700
- Post-check: PR body no longer contains blocked/draft/do-not-merge/do-not-review
  language; PR is OPEN + MERGEABLE + not-draft.

No branch push was performed for #1424 (none was needed).

---

## 2. osv-apps sync — synced branch created (CLEAN)

Existing branch (untouched): `wip/postgres18-musl-demo` (github.com/gburd/osv-apps),
tip `c0d2bad`.

New branch created and pushed: **`wip/postgres18-musl-demo-synced`**,
tip `c5c1790`.

- Throwaway clone `/tmp/osv-apps-sync` of gh-fork osv-apps; added cloudius remote
  and fetched cloudius/master (tip `b2d53b3`).
- Divergence confirmed (matches the sweep): our branch is 3 ahead, 4 behind,
  with **ZERO file overlap**:
  - Our 3 commits touch only `postgres18-musl/`.
  - Their 4 commits touch only `block-bench/`, `fio/`, `io-uring-bench/`.
- **Clean rebase**: `git rebase -S cloudius/master` of our 3 commits succeeded
  with no conflicts. Result sits cleanly on cloudius/master tip, all 3 commits
  signed (`%G? == G`), still touching only `postgres18-musl/`, and their app
  dirs are now present.
- **Leak scrub applied during the rebase** (the leak-scan flagged the AWS
  instance type `m5d.metal` in two files and two commit messages). Since the
  rebase recreates the commits anyway, `m5d.metal` / `... EC2 instance (AL2023,
  ...)` / `*.metal EC2` were rewritten to generic "bare-metal x86_64 host"
  wording in both commit messages (reworded, re-signed) and in
  `postgres18-musl/README.md` + `postgres18-musl/fc-snapshot.sh` (amended into
  the owning commits, re-signed). Generic performance numbers and Greg Burd
  authorship were preserved. Final leak-scan of messages and diff is clean; the
  only remaining `snap-` matches are Firecracker CLI flag names
  (`--snap-vmstate`, `--snap-mem`), not AWS resource IDs.
- Pushed the NEW branch only; the existing `wip/postgres18-musl-demo` was NOT
  overwritten. Both branches now coexist on gh-fork osv-apps.

Branch URL:
https://github.com/gburd/osv-apps/tree/wip/postgres18-musl-demo-synced

Note for the human: the original `wip/postgres18-musl-demo` still contains the
un-scrubbed `m5d.metal` references in its (already-public) commits; the synced
branch is the scrubbed one.

---

## 3. numa.cc hardening PR — WARRANTED and OPENED

New PR: **#1482** — https://github.com/cloudius-systems/osv/pull/1482
Head: `gburd:pr/numa-harden` -> base `cloudius-systems/osv:master`
(OPEN, MERGEABLE, not-draft). Commit `144d016fe`, signed (`%G? == G`).

Copilot findings on #1438/#1441 were checked against CURRENT master
(SRAT/SLIT discovery merged at a92c44f9b). Result:

Findings that STILL APPLY to master's `core/numa.cc` (fixed by this PR):
- **SRAT subtable walk**: the loop only checked that a subtable *starts* before
  `end` and that `Length != 0`; a subtable whose `Length` overruns the table
  (or an SRAT header shorter than the table struct) was still dereferenced ->
  out-of-bounds read on untrusted firmware tables. Fixed with an explicit byte
  cursor + a `cur + s->Length > end` / short-header bounds check (which also
  drops the non-standard `void*` pointer arithmetic, a GNU extension).
- **`parse_slit()`**: read `n*n` distance bytes from `Entry` without verifying
  they fit within `Header.Length`, and `n*n` could overflow. Fixed with an
  `offsetof(Entry) + n*n <= Header.Length` check plus an `n*n` overflow guard.

Findings that DO NOT apply to master (no action):
- `node_of_phys()` overflow — that function does not exist in master's
  numa.cc/numa.hh; superseded by the merged discovery code.
- `s_nr_nodes = max_node + 1` sparse-proximity-domain inflation — a design
  change (dense node-id remapping), not a memory-safety bug; node count is
  bounded by real hardware and it would need its own test coverage.
  Deliberately left out to keep the hardening focused. (Recorded as a possible
  follow-up, not filed.)
- `get_mempolicy()` MPOL_F_ADDR EFAULT and nmask-clearing (linux.cc) — master's
  `linux.cc` still has the OLD stock `get_mempolicy` stub ("OSv has no support
  for NUMA nodes"); the numa-aware wiring from #1438/#1441 is NOT merged, so
  these findings are PR-scoped, not master issues. No action.

The commit message and PR body cite the specific code issues only; they do NOT
reference #1438/#1441/#1445 or use "campaign" language. Bounds arithmetic was
validated with a standalone `assert`-based self-check (SRAT overrun,
short-header, and truncated-SLIT cases all pass).

---

## 4. Banked-rebase inventory (verify only — NOT pushed)

15 `bank/*` branches exist on codeberg (origin). The 13 `bank/NNNN-*-rebased`
branches each correspond to an OPEN, non-draft upstream PR:

| bank branch | PR | PR head | PR title (short) |
|---|---|---|---|
| bank/1439-signalfd-rebased | #1439 | pr/signalfd | signal: implement signalfd(2) |
| bank/1440-inotify-rebased | #1440 | pr/inotify | fs: implement inotify(2) |
| bank/1449-ext-readlink-rebased | #1449 | pr/sec-ext4-readlink | libext: fix heap overflow in ext_readlink/ext_readdir |
| bank/1450-sec-driver-backend-rebased | #1450 | pr/sec-driver-backend | drivers: validate device-supplied completion ids |
| bank/1455-feat-fork-rebased | #1455 | wip/feat-fork | process: thread-backed fork/vfork/execve/waitpid (FORK TRILOGY - do not touch) |
| bank/1461-rng-reseed-rebased | #1461 | pr/rng-reseed-on-resume | random: reseed CSPRNG on hypervisor resume |
| bank/1463-virtio-net-multiqueue-rebased | #1463 | pr/virtio-net-multiqueue | virtio-net: implement multiqueue (VIRTIO_NET_F_MQ) |
| bank/1464-sched-load-balance-rebased | #1464 | pr/sched-load-balance | sched: disperse threads faster in the load balancer |
| bank/1465-msix-vector-budget-rebased | #1465 | pr/msix-vector-budget | drivers: bound MSI-X vector use |
| bank/1467-net-batch-wakeup-rebased | #1467 | pr/net-batch-wakeup | net: batch per-connection wakeups in virtio-net receiver |
| bank/1470-virtio-net-rss-rebased | #1470 | pr/virtio-net-rss | virtio-net: implement RSS (VIRTIO_NET_F_RSS) |
| bank/1471-nitro-inbound-tcp-rebased | #1471 | pr/nitro-inbound-tcp | drivers/ena, drivers/nvme: fix inbound TCP on AWS Nitro |
| bank/1472-sched-idle-pull-rebased | #1472 | pr/sched-idle-pull | sched: idle-CPU pull work-stealing |

Two additional bank branches do NOT map to a numbered PR (RX NAPI work banks):
- bank/rx-napi-full
- bank/rx-napi-signed

These 15 banked branches were VERIFIED to exist only. None were pushed to any
public PR head. If a rebase needs to land on a public PR head, the human should
force-push-with-lease it (hooks may block automated force-pushes).

---

## Summary of remote changes made by this sweep

- cloudius-systems/osv #1424: PR body edited + comment posted (no branch push).
- cloudius-systems/osv #1482: NEW PR opened (numa.cc hardening).
- github.com/gburd/osv-1 (gh-fork): NEW branch `pr/numa-harden` pushed.
- github.com/gburd/osv-apps (gh-fork): NEW branch
  `wip/postgres18-musl-demo-synced` pushed (existing wip branch untouched).

Nothing merged to master. Fork trilogy (#1455/#1456/#1458/#1459/#1475) not
touched. No force-pushes to any public PR head. All `/tmp` worktrees/clones
created by this sweep were removed (`git worktree remove` + `prune`).
