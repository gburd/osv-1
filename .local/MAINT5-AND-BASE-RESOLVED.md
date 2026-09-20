# Maintenance round 5 + clean-base resolution (2026-09-06)

Both agents ran out of context before printing their final structured reports, so
these findings were recovered from their transcripts and re-verified by me
directly. Both boxes accounted for; 0 EC2 orphans.

## THE HEADLINE: the clean benchmark base is settled

**#1456 is load-bearing. Base = upstream/master + #1456 (alone).**

- Base A (master + #1455) builds and boots, PostgreSQL starts and listens, then
  **aborts reproducibly in `fork+37` with an mmap fault at PG's first fork()**.
- The reason is in #1455's own docs: the child **shares heap and globals** (only
  the stack is copied). That is exactly the gap #1456's per-child COW fills. So
  #1455 alone cannot host PostgreSQL by design, not by bug.
- Both critical fixes confirmed present on the base (AE_OK / AF_OK): `ae077860c`
  (virtio-blk lock inversion = the 19-second p99 stalls) and `af27ba4b7` (libext
  real fsync). So the base is uncontaminated for the p99 re-measurement.

**Topology correction (simplifies the work):** #1456 merges onto upstream/master
DIRECTLY with exactly ONE conflict (`libc/signal.cc`), and carries
`libc/process/fork.cc` itself. #1455 and #1456 are NOT base + increment - #1456 is
the fuller revision. The 10-file add/add mess only appears if you merge BOTH,
which is the wrong thing to do. Verified with merge-tree from a master worktree.

Next step: build master + #1456, resolve `libc/signal.cc` SEMANTICALLY (upstream's
POSIX default-ignore for SIGCHLD/SIGURG/SIGWINCH vs our SIGURG latch routing - do
not take a side wholesale), confirm PG serves and survives 32 concurrent backends,
then run the p99 sweep against P1's falsifiable criterion (0 probe samples >=5s at
VU32 in baseline A before any knob comparison is believed).

## Maintenance round 5

**MY ERROR, caught by the agent: we have 42 open PRs, not 30.** My brief said 30
because an earlier `gh pr list` hit the default page limit and silently truncated.
Verified: 42 open, all authored by gburd. Any future count must pass
`--limit 100`.

- **Upstream has not moved since 2026-08-17** (`0e34e4dc2`). So no new drift, and
  nothing newly merged that affects an open PR.
- **No reviewer is waiting on us.** The only reviewer activity found is Copilot
  comments from early August, all already answered. #1464 remains APPROVED awaiting
  maintainer merge.
- **Dependencies current.** OpenZFS 2.4.4 is still the newest release (2.4.99 is a
  dev tag), so #1488 is current. musl still the 1.2.1 fork (deliberate backlog).
  No dep drift affects an open PR.
- **lwext4 draft still correctly marked DO-NOT-FILE** - verified the header is
  intact: "DO NOT FILE THIS REPORT. IT IS WRONG. Status: SUPERSEDED / WITHDRAWN".
  Nothing was filed.
- **#1476 (idle-spin) correctly left DRAFT.** It is behind=0 and merges clean, but
  P1 measured that its knob does NOT help the tail, so readying it would ship an
  unvalidated tunable.
- **Nothing readied**, correctly - no feature met finished + dependency-merged +
  re-validated.

## Process lessons recorded

1. `gh pr list` truncates at a default page size. Always pass `--limit 100` before
   quoting a count.
2. Long build-and-test agents should report their box id in their FIRST message so
   cleanup never depends on them finishing. Both agents this round exhausted
   context before their final report; I terminated i-06bb64dc380d06365 myself.
3. `pgbench` is not in AL2023's base postgresql client package - install
   postgresql16-contrib or drive load from the HammerDB host.
