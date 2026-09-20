# Clean base RESOLVED: master + #1456 alone. #1456 is load-bearing.

Determined 2026-09-06 (agent 053e2e44, box terminated by me after it ran out of
context mid-run; 0 orphans).

## The question and the answer

Question: does PostgreSQL run on master + #1455 (fork) WITHOUT #1456 (per-child
COW address space)?

**Answer: NO. #1456 is load-bearing.**

Base A = master + #1455 builds and boots, PostgreSQL starts and listens, then
**aborts reproducibly in `fork+37` with an mmap fault at PG's FIRST fork()**. It
never reaches "ready to accept connections" for a real workload.

The reason is in #1455's own documentation, which the agent spotted: the fork doc
says the child **shares heap and globals** (only the stack is copied). That is
exactly the gap #1456's per-child copy-on-write address space fills. So #1455
alone cannot host PostgreSQL, by design rather than by bug.

Both critical fixes WERE confirmed present on base A (AE_OK / AF_OK):
`ae077860c` (virtio-blk lock inversion, the 19-second p99 stalls) and
`af27ba4b7` (libext real fsync). So the base choice is purely about fork.

## The topology correction that simplifies everything

My earlier reading was that #1456 must stack on top of #1455 (10 conflicted files
with add/add on the fork implementation). That framing was wrong in a useful way.

**#1456 merges onto upstream/master DIRECTLY with exactly ONE conflict**
(`libc/signal.cc`), and **#1456 carries `libc/process/fork.cc` itself** - it
contains its own fork base. Verified with merge-tree from a worktree checked out
at master:

    merge-tree upstream/master gh-fork/wip/fork-stage2-pr
    -> exit 1, 1 conflict: CONFLICT (content): libc/signal.cc
    git ls-tree wip/fork-stage2-pr libc/process/fork.cc -> present

So #1455 and #1456 are not base + increment; #1456 is the fuller revision. The
10-file add/add mess appears only if you merge BOTH, which is the wrong thing to
do.

## The clean benchmark base

    base = upstream/master + gh-fork/wip/fork-stage2-pr   (#1456)
    one conflict to resolve: libc/signal.cc

That base contains `ae077860c` and `af27ba4b7`, so it is uncontaminated for the
p99 re-measurement, and it has the per-child COW address space PostgreSQL needs.

Next step: build it, resolve `libc/signal.cc` semantically (upstream's POSIX
default-ignore change for SIGCHLD/SIGURG/SIGWINCH vs our SIGURG latch routing -
do not take a side wholesale), confirm PG serves and survives 32 concurrent
backends, then run the p99 sweep against P1's pre-written falsifiable criterion
(0 probe samples >=5s at VU32 in baseline A before any knob comparison is
believed).

## Process notes

- The agent hit a genuine environment issue worth recording: `pgbench` is not in
  the AL2023 postgresql client package it installed, so step 3 needed a different
  driver. Install `postgresql16-contrib` or build pgbench, or drive from the
  HammerDB host.
- It also correctly aborted a merge that had run on the wrong branch after a dirty
  checkout was refused, and redid the work in a fresh clone. Right instinct.
- It ran out of context before terminating its box; I terminated
  i-06bb64dc380d06365 and confirmed 0 orphans. Long build-and-test agents should
  report the box id early so cleanup never depends on them finishing.
