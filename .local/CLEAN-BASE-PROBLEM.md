# The clean-base problem: master cannot build PostgreSQL, and the fork PRs overlap

Investigated 2026-09-05 while trying to define a fresh benchmark base for the p99
re-measurement. This is the real blocker behind P0.4, and it is not what I assumed.

## Master has every fix we need, but no fork()

Confirmed in master:
- `ae077860c` virtio-blk lock inversion (the p99 stall) - IN
- `af27ba4b7` libext real fsync (the lwext4 phantom bug) - IN
- `1e3d84143` virtio-blk multiqueue - IN
- `0e34e4dc2` OpenZFS keystone - IN

Also confirmed in master:
- `libc/process/fork.cc` - DOES NOT EXIST
- `conf/kconfig/threads` has no `config fork`

PostgreSQL requires `fork()`. So the clean base CANNOT be master alone. It must be
master plus the fork stack, which is still maintainer-gated (#1455, #1456 both
open, unreviewed).

## #1455 merges clean onto master; #1456 does not stack cleanly on it

- `merge-tree upstream/master gh-fork/wip/feat-fork` (#1455): **exit 0, zero
  conflicts**. Merging it does produce `libc/process/fork.cc`.
- Then merging #1456 (`wip/fork-stage2-pr`) on top: **10 conflicted files**, not
  the one I first misread from the merge output:

      AA arch/aarch64/fork.cc        AA include/osv/fork.hh
      AA arch/x64/fork.cc            UU libc/process/execve.cc
      UU conf/kconfig/threads        AA libc/process/fork.cc
      AA documentation/fork.md       UU libc/signal.cc
      AA tests/tst-execve.cc         AA tests/tst-fork.cc

The `AA` (add/add) pattern on the fork implementation files is the tell: **#1456
is not a clean increment on top of #1455, it is a revised version of the same
work.** Both branches independently add `libc/process/fork.cc`,
`arch/*/fork.cc`, `include/osv/fork.hh`. They are alternative presentations of
the fork feature, so they cannot simply be stacked by merging.

CORRECTION: my first reading of the merge output said "one trivial test-file
conflict". That was wrong - I saw `CONFLICT ... tests/tst-fork.cc` scroll past and
concluded it was the only one without checking `git status`. The kernel-side
conflicts (`libc/signal.cc`, `libc/process/execve.cc`, `conf/kconfig/threads`) are
real and substantive.

## What this means for the plan

1. There is no quick "master + two merges" clean base. Producing one requires
   deciding how #1455 and #1456 compose - which is a question for the maintainer,
   since it is about how the fork feature should be presented upstream, not a
   mechanical rebase.
2. The p99 re-measurement therefore cannot be done on a pristine-master base
   today. Options, in order of honesty:
   a. Measure on master + #1455 alone (fork without the per-child COW address
      space) if PostgreSQL runs on that - simplest defensible base, and it DOES
      contain `ae077860c`, so the p99 stall is gone. Verify PG works there first.
   b. Take v26 and merge current master into it (not a rebase), accepting a
      messier history but getting `ae077860c` + `af27ba4b7` into the measured tree.
      Cheapest path to an uncontaminated number.
   c. Wait for the maintainer on #1455/#1456. Blocks indefinitely.
3. Recommendation: try (a) first. If PostgreSQL needs #1456's per-child COW to run
   multi-backend workloads, fall back to (b) and label the base precisely.

## Standing note

This is the third time an assumption about branch topology has been wrong in this
program (the #1449 false conflict, the "129 orphaned commits" overstatement, and
now "one trivial conflict"). Every topology claim must be checked with
`git status` / `merge-tree` output rather than skimmed from merge stdout.
