# OSv forked-backend churn wedge: TWO leaks named; leak #1 (fds) FIXED + validated (2026-09-16)

## Box
- METAL: **i-0dc1686c0531c83b0** m5d.metal, us-east-2, acct 769093516156 (lava), Owner=agent-leakhunt
- Debian 12 host, native qemu 7.2.22 -M pc, raw /dev/nvme0n1 passthrough (cache=none aio=native),
  32 vCPU / 32 GiB guest. OSv branch gh-fork bench/leakhunt (base 90ddedaf bench/writedepth +
  OSV_LEAK_PROBE probe + the fd-reap fix), apps 3f93f43, OpenZFS 2.4.2, bench-base-gate PASS,
  FDMAX=0x10000=65536.

## Repro (cheap, no HammerDB): churn loop = M rounds x 32 parallel PG connections, each a trivial
## txn (or bare SELECT 1), autovacuum ON. Each round forks+reaps 32 backends. Guest-internal
## in-kernel probe (OSV_LEAK_PROBE=5) prints one LEAKPROBE line/5s to the console.

## LEAK #1 (FIXED): file-descriptor leak in the shared global fd table (gfdt) on backend reap
ROOT CAUSE (libc/process/fork.cc release_inherited_fds): the reaper did `g_child_opened_fds.erase()`
- it FORGOT the fds a backend opened AFTER fork but NEVER closed them in the shared gfdt (only
INHERITED fds were fdrop'd). OSv keeps ONE global fd table; on real Linux process-exit closes the
whole table, but here the shared-table reaper leaked every child-opened fd. -> gfdt fills to FDMAX
-> pipe()/accept() fail EMFILE -> hard wedge (reboot-resettable).

FIX (env-gated OSV_FORK_FD_REAP, default ON): on reap, snapshot g_child_opened_fds[child_as] under
g_fd_lock, release the lock, then for each fd call fork_reap_close_child_opened_fd(fd) (new helper in
fs/vfs/kern_descrip.cc: under gfdt_lock read fp=gfdt[fd], null the slot, then fdrop OUTSIDE the lock).
Child-opened fds are solely owned by the exited backend (post-fork open got a fresh gfdt slot), so
they close unconditionally - no last-inheritor dance, no double-close (fork_child_owns_fd already
erases an fd when the backend closes it, so only still-open fds remain at reap).

### QUANTITATIVE A/B (gfdt occupancy = the leak counter), identical 32-conn churn, 250 rounds:
| round | FIX OFF (OSV_FORK_FD_REAP=0) gfdt | FIX ON (default) gfdt |
|-------|-----------------------------------|-----------------------|
| R1    | 32       | 29 |
| R49   | 13219    | 49 |
| R97   | 28083    | 49 |
| R146  | 41804    | 50 |
| R194  | 56149    | 30 |
| R218  | 64023    | 43 |
| R242  | **65535 (FDMAX)** | 37 |
| R250  | 65535    | 30 |
| **peak gfdt** | **65536 (FDMAX)** | **55** |
| **first failure** | **round 223 (EMFILE, ok=0 fail=32)** | **NONE (all 250 rounds ok=32)** |

Fix OFF: gfdt climbs ~290 fds/round to FDMAX, wedges at R223. Fix ON: gfdt FLAT ~29-55 through
R250, zero failures. The fd leak is ELIMINATED. (Both arms show mem_free declining = leak #2,
independent of the fd fix.)  Data: .local/leakhunt/AB-off.log, AB-on.log.

## LEAK #2 (NAMED, not yet fixed): unreclaimable per-fork MEMORY leak (surfaces once fds are fixed)
With leak #1 fixed, the guest still wedges - now via OOM, ~round 280:
  mem_free_mb: 23653 -> 15085 -> ... -> 597 -> 29, monotonic; console: "Out of memory: could not
  reclaim any further" (UNRECLAIMABLE - NOT ARC; ARC would shrink under pressure).
- Per-fork, NOT per-query: a PURE connect/disconnect churn (bare `SELECT 1`, no write txn) leaks the
  same way: mem_free 15087 -> 8069 over 150 rounds / ~9450 backends = **~0.74 MB leaked per reaped
  backend.** gfdt stays flat (~35) throughout - independent of leak #1.
- NOT threads (flat ~658), NOT live_child_address_spaces (flat ~5-7, ASes ARE destroyed), NOT the
  reaper queue (flat), NOT the fork bookkeeping maps (flat).
- MECHANISM HYPOTHESIS (source, not yet A/B-proven): the 512 MiB fork-arena (core/fork_arena.cc) is a
  monotonic global bump pointer that EXHAUSTS by ~round 2 (arena_used_mb hits 512 immediately). After
  exhaustion, a backend's malloc falls back to the IDENTITY (kernel) heap, whose allocations are NOT
  tied to the backend's address space and so are NOT freed by destroy_address_space on reap. A PG
  backend's ~0.5-1 MB of per-connection local allocations (relcache/catcache/memory contexts) thus
  leak on the identity heap once the arena is full. (destroy_address_space DOES free the child's
  private COW page-table pages incl. the arena slot 96, which is within [1,127]; the leak is the
  identity-heap fallback allocations, not the AS pages.) NEEDS: identity-heap-per-AS accounting or a
  bigger/recyclable arena to confirm + fix. This is a SEPARATE, deeper fork/teardown fix.

## STATUS / DELIVERABLE
- Leak #1 (fds): NAMED + FIXED + quantitative A/B validated (flat-vs-wedge gfdt). Landable generic fix.
- Leak #2 (memory): NAMED + characterized (per-fork, ~0.74MB/backend, unreclaimable, identity-heap
  fallback hypothesis). Fix deferred (deeper). The wedge has TWO independent causes; fixing #1 moves
  the wedge from ~round 224 (EMFILE) to ~round 280 (OOM).

## PR TARGET: the gfdt/g_child_opened_fds fork model is on the FORK stack (commits f411d5edc,
## 9108df4b5, a377258ce, 56357aa11, 8c8f53d2d - the PR #1455/#1456 line), CONFIRMED NOT on
## upstream/master (git grep g_child_opened_fds upstream/master = empty). So the fd fix belongs
## STACKED ON the fork-fd-table PR, NOT standalone vs master. Branch pushed: gh-fork bench/leakhunt
## commit ac6a389d2 (source verified md5-identical to what built + validated on the box).

## TERMINATE: aws ec2 terminate-instances --profile lava --region us-east-2 --instance-ids i-0dc1686c0531c83b0
