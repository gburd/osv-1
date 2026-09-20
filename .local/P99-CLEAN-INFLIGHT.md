# Clean base BUILT, p99 sweep IN FLIGHT

## The clean base (done, pushed)

    branch wip/pg-clean-base @ 252c14731  (gh-fork = github.com/gburd/osv-1)
    = upstream/master + PR #1456 (per-child COW fork)

Built by me 2026-09-06. The single expected conflict, `libc/signal.cc`, turned out
to be **comment-only**: both sides make the identical functional change
(`if (sig == SIGCHLD || sig == SIGURG || sig == SIGWINCH) return 0;` instead of
powering off). Upstream had independently made the same POSIX fix we did. So there
was no semantic decision to make - I merged the two explanations, keeping both the
POSIX rationale and the fork-specific motivation (fork raises SIGCHLD to the
parent when a child exits; treating it as fatal would power off the VM).

Verified on the merged base:
- `ae077860c` (virtio-blk lock inversion, the 19-second stalls) - IN
- `af27ba4b7` (libext real fsync) - IN
- `1e3d84143` (virtio-blk multiqueue) - IN
- `libc/process/fork.cc` - present
- `req_done()` in drivers/virtio-blk.cc confirmed draining OUTSIDE
  `WITH_LOCK(_queue_locks[q])` - i.e. the fix is really in the source, not just in
  the commit graph

Commit is G-signed.

## The sweep (agent dbae1d92, box osv-p99-clean i-04e1f51fd1a9d0cdd)

Running against P1's falsifiable criterion, written BEFORE this run:

**GATE: at VU32 in baseline A, the independent probe must record 0 samples >= 5s.**
- PASS -> the tail is clean, knob comparisons become meaningful, proceed to sweep.
- FAIL -> `ae077860c` was not the whole story; root-cause the second stall rather
  than tune. That would be the more valuable result.

**Expected confirmation if the fix worked:** baseline A's per-VU MAX collapses from
~19,000 ms toward ~1,000 ms, and configs A, C, D CONVERGE (previously A had a
20,542 ms MAX while C/D sat at ~1,100-1,300 ms). That convergence is the proof.

Contaminated old numbers to beat, for quantifying the improvement:
old base A = NOPM 288,460, p99 10.04 ms, MAX 20,542 ms, probe had 3 samples >=5s
including one at 19,327 ms.

The independent probe (a `select 1` loop from outside the load, timed, counting
samples >=1s/>=5s/>=10s) is the instrument that made the previous run conclusive -
HammerDB's own percentiles hid the stall entirely. It is mandatory again.

## Note on the B config

On the contaminated base, checkpoint smoothing (B) made the tail WORSE (6 stalls
>=5s) - which I read as a stall artifact, since more frequent checkpoints mean more
chances to saturate the ring. If B STILL hurts p99 on the clean base, that is a
genuine PostgreSQL-side finding worth keeping rather than an artifact.
