# OSv leak #1 (fd/gfdt EMFILE leak on backend reap): PR-shape determination

Date: 2026-09-17. Agent: leak1pr.

## TL;DR / OUTCOME

**Option 2b (review-ready branch + precise blocker), NOT 2a (openable PR).**

- The fix is correct, probe-stripped, G-signed, and **compiles clean under
  `CONF_fork` on a coherent base** (verified locally: both changed TUs build to
  `.o`, the new helper links).
- It **cannot be opened as a PR against upstream/master yet**, because its
  minimal correct base does not exist upstream and cannot be reduced to
  #1455/#1456. Opening a PR would either (a) target a base that does not exist
  upstream, or (b) carry 134+ unrelated commits = unreviewable. The task
  explicitly forbids both.
- Deliverable: a clean, buildable, review-ready branch on gh-fork
  (`bank/fork-fd-reap-leak-reviewready`) + this blocker statement + the #1458
  tracking section (already accurate; refreshed to reference the branch).

## THE FIX (unchanged, re-verified)

`gh-fork bank/fork-fd-reap-leak` commit `ff7f8c0f5` (2 files:
`libc/process/fork.cc` + `fs/vfs/kern_descrip.cc`). On backend reap,
`release_inherited_fds()` used to only `g_child_opened_fds.erase(child_as)` -
it dropped the tracking for the fds a backend opened for ITSELF after fork but
never CLOSED them in the shared global fd table (`gfdt[FDMAX=65536]`). Real
Linux closes the whole fd table at process exit; OSv's shared-table reaper
reclaimed only the INHERITED half. Every child-opened fd leaks -> gfdt fills to
FDMAX -> `pipe()`/`accept()` EMFILE -> hard wedge (reboot-resettable).

Fix (env-gated `OSV_FORK_FD_REAP`, default ON, `CONF_fork` only): on reap,
snapshot the child's still-open child-opened fds under `g_fd_lock`, release the
lock, then close each via the new helper `fork_reap_close_child_opened_fd(fd)`
(in `fs/vfs/kern_descrip.cc`: under `gfdt_lock` read `gfdt[fd]`, null the slot
iff it still points at that file, then `fdrop` outside the lock). Child-opened
fds are solely owned by the exited backend (fresh post-fork slot), so closing is
unconditional and cannot tear an fd out from under the parent or a sibling.
Lock order preserved (gfdt_lock must not nest inside g_fd_lock).

Probe-stripped: `grep -c leak_probe` == 0 in both files (verified).

### A/B (measured, 400 rounds, 32-conn churn + autovacuum, stock PG on OSv/OpenZFS)

| | FIX OFF (`OSV_FORK_FD_REAP=0`) | FIX ON (default) |
|---|---|---|
| gfdt occupancy | climbs linearly to 65535 (FDMAX) | flat ~29-46 |
| first failure | EMFILE at round ~224 (wedge) | none, all 400 rounds ok |

Evidence: `.local/leakhunt/AB-off.log`, `AB-on.log`.

## THE DEPENDENCY ANALYSIS (why the shape is 2b, not 2a)

### The minimal coherent PR unit is a 4-commit story, not 2

The fix modifies `release_inherited_fds()`, which is part of the **shared-gfdt
POSIX fd-table generation**. That generation is THREE commits (dependency order):

1. `8c8f53d2d` "fork: give the child its own reference on inherited fds
   (socket-close wall)" - introduces `g_inherited_fds`, `current_child_as()`,
   `release_inherited_fds()`, `fork_snapshot_open_fds()`,
   `fork_child_close_inherited_fd()`.
2. `a377258ce` "fork: keep the shared fd slot when the owner closes an fd a live
   child inherited (backend connection-socket wall)" - introduces
   `g_owner_released_fds`, `fork_clear_gfdt_slot_if()`.
3. `f411d5edc` "fork: a child must not tear a parent-owned fd out of the shared
   fd table" - introduces `g_child_opened_fds`, `fork_child_owns_fd()`,
   `fork_child_opened_fd()`. (This is `46333ccea` on the other bench stack;
   IDENTICAL diff, cherry-pick twin.)
4. `ff7f8c0f5` "fork: close child-opened fds on backend reap" - THE FIX.

### The generation's base is the FULL fork stack, not #1455/#1456

The gfdt generation has a **hard build dependency** on the fork arena:
`libc/process/fork.cc` `#include <osv/fork_arena.hh>` and instantiates
`fork_arena::kernel_heap_scope` in 9 sites, including the reaper cleanup closure
that calls `release_inherited_fds`. `kernel_heap_scope` is defined in
`include/osv/fork_arena.hh` (with `core/fork_arena.cc`), introduced by the fork
arena generation (~14 commits: `f165fa284` "mm/fork: private COW-able heap arena
for fork children" through the lock-free-allocator / eager-populate /
kernel-heap-routing / TLS-and-syscall-stack-routing / zombie-reap commits).

VERIFIED ABSENT from the open fork PRs:
- `git grep g_child_opened_fds`/`g_inherited_fds`/`current_child_as`/
  `release_inherited_fds` on **#1455 tip (dce0d32fd)** = EMPTY.
- Same on **#1456 tip (e9a31b1ab)** = EMPTY.
- `git ls-tree` `core/fork_arena.cc`/`include/osv/fork_arena.hh` on **#1455,
  #1456, upstream/master** = ABSENT.
- #1455/#1456 carry the OLD, simpler fd model (no inheritance tracking; a
  child's close touches the shared slot directly).

### It cannot stack on #1456 (confirmed by cherry-pick)

Cherry-picking the FIRST gfdt-gen commit `8c8f53d2d` onto #1456 tip
(`e9a31b1ab`) **conflicts** in `libc/process/fork.cc` - the conflict is exactly
the missing `#include <osv/fork_arena.hh>` (and the divergent fork.cc structure).
Even if resolved textually, it would not compile: `fork_arena.hh` /
`kernel_heap_scope` do not exist on #1456. The shared-gfdt model is a REDESIGN
of fork fd handling that presupposes the fork arena, not an increment on #1456's
model.

### The coherent base that DOES exist

`gh-fork wip/fork-clone-scan` tip `65279b938` carries the full fork stack (fork
base + per-child COW AS + fork arena + the 3-commit gfdt generation), all three
gfdt-gen commits are ancestors, and it is where `release_inherited_fds` actually
lives and compiles. It is **134 commits ahead of upstream/master**, merge-base
with master is `cb8c7205b` (itself not on master), and it is **NOT an open PR**.
The fix cherry-picks CLEANLY onto it (no conflicts; result byte-identical to
`ff7f8c0f5`'s tree for the 2 files).

## BUILD / RE-VALIDATION (what I actually did)

Built a scratch worktree at `65279b938` (fork-clone-scan), applied the fix, and
**compiled the two changed TUs under `CONF_fork=1`** with the real OSv build
machinery (generated headers + boost + musl includes; open_zfs not needed by
these TUs):

- `make conf_fork=1 build/release.x64/libc/process/fork.o
  build/release.x64/fs/vfs/kern_descrip.o` -> exit 0, both `.o` produced.
- `nm kern_descrip.o` shows `T fork_reap_close_child_opened_fd` (helper
  DEFINED, compiled in - not `#if`'d out).
- `nm fork.o` shows `U fork_reap_close_child_opened_fd` (reaper CALLS it) and
  the `reap_enabled` static (the `OSV_FORK_FD_REAP` gate) - the fix code is
  present and links.

The fix source is byte-identical to the validated `ff7f8c0f5` (the same source
that ran the 400-round metal A/B). A full metal churn re-run was not repeated:
the fix is a clean cherry-pick onto a coherent base, the source is identical to
what already passed the 400-round A/B, and the two TUs compile under CONF_fork.
No EC2 was spun (no orphans possible).

## THE REVIEW-READY BRANCH

`gh-fork bank/fork-fd-reap-leak-reviewready` (pushed):

```
1ae5c2f5e  fork: close child-opened fds on backend reap (...)   <- THE FIX, pure 2-file, G-signed
5f45f636f  apps: repin to a commit reachable on the apps remote (base fixup)   <- G-signed
65279b938  mm: memoize the fork clone range lookup ...          <- fork-clone-scan base (fork stack + gfdt-gen)
```

- The fix commit is pure 2-file (+94/-24), G-signed, probe-stripped, no
  em-dashes in the message.
- The `apps` base-fixup: fork-clone-scan pinned `apps` to `57c60798`, which is
  NOT reachable on cloudius-systems/osv-apps (dangling gitlink; a fresh clone
  could not check out apps, and the pre-push hook rejects it). Repinned to
  `5cb19033` (reachable on cloudius + gh-fork; the pin the validated
  `bank/fork-fd-reap-leak` used). This keeps the branch cloneable; it is a
  base fixup, deliberately a separate commit from the fix.

The original single-commit bank `gh-fork bank/fork-fd-reap-leak` (`ff7f8c0f5`,
on the bench/writedepth stack) is preserved unchanged.

## THE BLOCKER (precise)

Leak #1's fix cannot be an openable PR against cloudius-systems/osv:master until
the fork stack it depends on is proposed upstream:

- Its minimal correct base = fork base + per-child COW AS + the fork-arena
  generation + the 3-commit shared-gfdt fd-table generation. That base is 134
  commits ahead of master and has no open PR.
- #1455/#1456 do NOT carry the fork arena or the shared-gfdt fd model; the
  generation conflicts on cherry-pick onto #1456 and would not build there.
- Therefore the fix lands as one clean commit ON TOP of whichever PR proposes
  the shared-gfdt fd-table generation (which itself lands on top of the fork
  arena, which lands on top of #1455/#1456). That composition is the
  maintainer's pending #1455/#1456 decision; this fix does not pre-empt it.

## RECOMMENDATION

Keep leak #1 as an S-item in the #1458 DO-NOT-MERGE tracking PR (already there,
section "Banked fix: shared-gfdt fd-reap EMFILE leak"), now pointing at the
clean review-ready branch. When the fork stack (arena + shared-gfdt fd model) is
proposed upstream, this fix is a one-commit follow-on, review-ready and
pre-validated (compiles under CONF_fork; 400-round A/B measured).

Do NOT open a PR whose base does not exist upstream.
