# P1 result: the p99 tail is an OSv virtio-blk stall, already fixed upstream

Measured on HEAD 859210d54 (24 commits behind upstream/master). Box terminated,
0 orphans.

## Verdict

No PostgreSQL knob fixes this tail. It is an OSv guest block-layer stall that
upstream/master already fixes with `ae077860c` ("virtio-blk: do not hold the
per-queue lock while draining completions"), which our base LACKS while carrying
`1e3d84143` (multiqueue) that introduced it. Verified by ancestry and confirmed
in the v26 source: `req_done()` drains under `WITH_LOCK(_queue_locks[q])`
(virtio-blk.cc:393) while `make_request()` holds that same lock (:416) across
`vring::add_buf_wait()`, which sleeps waiting for GC (virtio-vring.cc:370-379).
Producer sleeps holding the lock; the completion thread needs it to drain; I/O
stops.

NO OSv PR OPENED - the fix exists upstream. Correct next action is the rebase.

## The decisive evidence

A 19.3 s stall in baseline A, seen by a probe connection OUTSIDE the load:

    ping_ms=19327
    LWLock|WALWrite|21     <- 21 backends convoyed behind the WAL lock
    IO|WalSync|1           <- exactly ONE backend inside fsync

and PG's own accounting for that same window:

    checkpoint complete: wrote 660322 buffers (63.0%); write=153.384 s,
      sync=0.033 s, total=154.064 s; sync files=50, longest=0.009 s

`sync=0.033s` while a bare `select 1` took 19.3 s. PG asked for a small fast
fsync; the guest block path did not return. `sync` stayed 0.008-0.079 s in EVERY
config while stalls hit 17-27 s, so this is neither checkpoint-fsync cost nor WAL
volume. The stall is below PostgreSQL.

## A-G table (VU32, 40wh) - ALL tail figures contaminated by the stall

| Cfg | Change | NOPM | p50 | p95 | p99 | MAX |
|---|---|---|---|---|---|---|
| A | baseline (1h/16GB ckpt) | 288,460 | 2.20 | 4.40 | 10.04 | 20,542 |
| B | ckpt smoothing 5min/0.9/8GB | 153,598 | 3.33 | 6.31 | 23.31 | 27,069 |
| C | bgwriter 10ms/1000/4.0 | 165,326 | 4.04 | 6.78 | 11.56 | 1,326 |
| D | WAL writer 20ms/64MB | 180,938 | 3.49 | 6.70 | 11.67 | 960 |
| E | B+C+D | 218,769 | 3.32 | 6.46 | 22.20 | 9,713 |
| G | E + OSV_IDLE_SPIN=100000 | 142,624 | 4.96 | 8.13 | 25.19 | 3,801 |

VU64: A64 162,067 NOPM p99 32.66 MAX 12,365 | D64 114,268 p99 51.70 MAX 24,273.

NO winning latency profile is claimable. Baseline A has both the best p99
(10.04 ms) and the best NOPM; every alternative is worse on both. The p99 spread
(10-25 ms) sits on a stall term of 1-27 SECONDS - three orders of magnitude
larger - so knob effects are noise on top of the stall.

## What IS real: C and D suppress stall FREQUENCY (mitigation, not fix)

Independent probe (`select 1` from outside the load) - the cleanest signal:

| Cfg | median | p95 | max | >=1s | >=5s | >=10s |
|---|---|---|---|---|---|---|
| A | 182ms | 1,072ms | 19,327ms | 6.2% | 3 | 1 |
| B | 178ms | 4,259ms | 20,003ms | 9.2% | 6 | 2 |
| C | 174ms | 297ms | 1,186ms | 1.2% | 0 | 0 |
| D | 176ms | 325ms | 1,122ms | 1.2% | 0 | 0 |
| E | 178ms | 263ms | 8,978ms | 1.9% | 2 | 0 |
| G | 176ms | 452ms | 2,373ms | 1.2% | 0 | 0 |
| A64 | 212ms | 725ms | 3,072ms | 4.6% | 0 | 0 |
| D64 | 215ms | 3,521ms | 20,003ms | 10.7% | 4 | 2 |

C (aggressive bgwriter) and D (prompt WAL flush) eliminated EVERY >=5 s stall and
cut worst case ~17x. Mechanically consistent: smaller steadier batches keep the
virtio ring from saturating. They reduce how often the ring fills; they do not
remove the lock inversion.

B (checkpoint smoothing) made it WORSE (6 stalls >=5 s, max 20 s) - the original
hypothesis is INVERTED on this base, because more frequent checkpoints mean more
chances to saturate the ring.

The mitigation does not survive concurrency: D64 regressed to 4 stalls >=5 s and
a 20 s max. At VU64 the ring fills regardless of PG tuning - exactly what the
virtio-blk mechanism predicts, and the strongest argument that this is not
fixable from the PG side.

OSV_IDLE_SPIN did not help: the tail is I/O-completion latency, not idle-wake
latency. The implicated OSv lever is virtio-blk, not the scheduler.

## Re-measurement plan after P0.4 (falsifiable)

1. Confirm the fix is in: `git merge-base --is-ancestor ae077860c HEAD` passes,
   and `req_done()` drains OUTSIDE `WITH_LOCK(_queue_locks[q])`.
2. Re-run A, C, D at VU32 first. If the stall was the lock inversion, A's MAX
   should collapse from ~19 s toward C/D's ~1 s and A/C/D should CONVERGE - that
   convergence is the confirmation.
3. Gate on the probe, not xtprof: pass criterion is 0 samples >=5 s at VU32 in
   baseline A. Until then p99 is contaminated and knob comparison is meaningless.
4. Then re-sweep B and E. B's inversion should disappear; if B still hurts p99
   post-rebase, that is a genuine PG-side finding worth keeping.
5. VU64 is the real test. If it still shows multi-second MAX after the rebase, the
   remaining cause is NOT ae077860c and deserves fresh root-causing (check ring
   size / num-queues, and whether add_buf_wait still sleeps under any lock).
6. Keep log_checkpoints=on and watch `write=` vs `sync=`: small `sync` while
   clients stall seconds is the fingerprint that the stall is below PG.
7. Re-sweep OSV_IDLE_SPIN only after the tail is clean.

## Environment notes for the next agent

- Host qemu 11.0.0 (AL2023) hangs OSv at "random: device unblocked"; the
  fedora:39 container's qemu 8.1.3 boots reliably via `-kernel loader.elf` (the
  qcow2 MBR path triple-faults).
- `--extra-zfs-pools` only fires on the zfs-root path; a ramfs-root image needs an
  explicit `/zpool.so import -f -a` before postgres.
- Size the pool: a 60 G pool hit ENOSPC at 96% mid-sweep (re-run on 300 G, with a
  vacuum between runs).
