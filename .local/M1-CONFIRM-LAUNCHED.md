# M1 confirmation + maintenance sweep 2 running in parallel (2026-09-14)

## Two agents, no collision
- **0c90e588 (M1 confirmation):** the end-to-end #1509 test. Base bench/m1-confirm (8f1a560de) = walwake
  stack + deadlock-CORRECTED per-queue completion. Same-image A/B OSV_BLK_MQ_COMPLETE off vs on, then
  matched Linux. Tag Owner=agent-m1confirm. Answers: does per-queue completion move NOPM and stop the
  VU8->VU16 decline?
- **11dee939 (maintenance sweep 2):** PRs/deps/upstream/sync/tidy. Read-mostly; told HANDS OFF all bench
  branches, the just-filed PRs, and any running agent box (incl the m1confirm box launching).

## The confirmation base fixed a latent deadlock before it could bite
bench/walwake-mt's req_done_q took WITH_LOCK(_queue_locks[qid]) during drain - which deadlocks against
a producer sleeping in add_buf_wait() under ring-full pressure (the isolate never filled the ring;
HammerDB will). bench/m1-confirm (and the filed PR #1509) drain LOCK-FREE (single-consumer per queue,
races the producer only on the u16 used-ring head). Gate PASSES with #1509. This is exactly the kind of
correctness check that must precede a load run - a deadlock-prone fix would have wedged HammerDB and
wasted the box.

## The prediction
PERQ arm stops the VU8->VU16 decline (the completion serialization was why NOPM fell 104k->65k). How
close to Linux 269k it gets is the open number. If PERQ ~= SINGLE, HammerDB is bottlenecked before the
completion path matters (valid null, redirects). Watch for a wedge on PERQ (would mean the lock-free
correction did not hold - critical).

## After this: the FULL projected-merged base run (ship-readiness)
The M1-confirm base is the minimal-delta A/B (isolates #1509). Separately, build the full
projected-merged base with `build-projected-base.sh --manifest M`: plan first, then `--apply
candidate/<name> --worktree <new-path>` after a clean plan. Resolve each conflict once as a reviewed
ALTERNATIVE(<sha>) row (fork stack #1456, NUMA add/adds, #1502->#1503 order). This gives the truest
future-OSv number. #1508 and #1509 are in it only if their manifest rows say INCLUDE.

## Session M1 PR arc (all master-facing, generic G2)
#1502 AB-BA (e2e proven) | #1505 ZIL hires | #1506 ARC-max | #1507 fsync scan | #1508 physio per-iovec |
#1509 virtio-blk per-queue completion | #1472 wake-pull default-on. Gate scripts:
bench-preflight.sh (the launch gate), build-projected-base.sh (composition from a manifest).
bench-base-gate.sh is a smoke test only. 56 open PRs.

## Validity check steered into 0c90e588 (2026-09-14)
The agent added one host iothread + num-queues=CPUS to the pool disk. Flagged two things that could
silently make PERQ read as SINGLE for a SUBSTRATE reason (invalidating the A/B):
  1. A single host iothread may funnel all completions through one interrupt vector -> guest sees ~one
     queue's completions -> per-queue threads have nothing to parallelize. May need iothread-vq-mapping
     or no explicit iothread. Cheap check: confirm >1 req_done_q thread does work in PERQ mode.
  2. WAL must be on the multiqueue device (hd1/ZFS pool), not a separate single-queue disk. Confirm via
     SHOW data_directory + df on pg_wal + the pool vdev.
A PERQ~=SINGLE result is only meaningful if the fix was actually exercised at the DEVICE level. Told the
agent to fix the host queue/interrupt setup first if either fails. This is the same "prove the
independent variable really varies" discipline as the boot-flag console lines.

## Tag collision caught + coordinated (2026-09-14)
The m1confirm boxes launched tagged Owner=agent-a2abench7 (reused launch script hardcoded the old tag):
  i-016b920108bf9e216 (m5d.metal), i-01dabeee6f235c8c3 (c5.4xlarge).
- Steered 0c90e588 to re-tag them to agent-m1confirm (instant, non-disruptive).
- Steered the maintenance agent 11dee939 NOT to reap them: they show a stale-looking tag but launched
  minutes ago; told it to cross-check LaunchTime before terminating ANY agent-* box (old + owner-done),
  and to leave-and-report when in doubt.
Lesson: launch scripts hardcode the Owner tag; a reused script carries the WRONG owner. Standing fix:
benchmark agent briefs should set the tag from the agent id, and the tidy agent must gate termination on
LaunchTime, not tag alone.
