# WRITE+DEPTH cycle - FINAL REPORT (agent-writedepth, 2026-09-15, Debian m5d.metal)

## BOX IDS (reported first, terminated at end - see teardown confirmation below)
- METAL:  i-0179b5abdcea6333b  m5d.metal  us-east-2b  (raw /dev/nvme0n1 passthrough, XFS /work on nvme1n1)
- DRIVER: i-0929075f9348808d7  c5.4xlarge us-east-2b  (HammerDB 6.0)
Host: Debian 12 (kernel 6.1.0-53-cloud), native qemu 7.2.22 (-M pc) for OSv boot; fedora:39 container for build.
Substrate: raw instance-store NVMe passthrough cache=none aio=native BOTH arms (confirmed: no fs on nvme0n1).

## RESULT IN ONE LINE
The M1 write-issue-depth deficit is the OSv cross-vCPU WAKE latency of the next ZIL committer (lever b),
NOT the write path and NOT a cap/window.  The upstream-faithful fix is the EXISTING OSV_IDLE_SPIN
scheduler knob (no new thread, no zil.c change): on the syncwrite isolate it CLOSED the gap
(+56-140% op/s, OSv reaches/exceeds Linux).  The HammerDB transfer is UNVERIFIED - blocked by a PG-guest
seed substrate failure, not by the lever.  Honest status: microbenchmark gap closed; TPROC-C M1 verdict
pending a stable PG seed.

## STEP 1 - DISCRIMINATOR (write-slower vs fewer-in-flight): BOTH, DEPTH dominates
Matched OSv-vs-Linux, same m5d.metal, same raw /dev/nvme0n1, matched ZFS, identical depth gauge, t8/16/32.
NEW probe 0041 (RESULT ZILSVC): per-write-zio DEVICE SERVICE time (io_delay) + vdev-queue write depth.
| thr | OSv SVC | Linux SVC | ratio | OSv lwb-depth | Linux lwb-depth | OSv op/s | Linux op/s |
|-----|---------|-----------|-------|---------------|-----------------|----------|------------|
|  8  | 190us   | 100us     | 1.89x | ~1.4          | 2.4             | 12000    | 25000      |
| 16  | 201us   | 128us     | 1.57x | ~1.7          | 12.2            | 18872    | 34500      |
| 32  | 199us   | 168us     | 1.19x | ~1.4          | 12.9            | 31846    | 45700      |
- OSv device write is genuinely ~1.9x slower UNCONTENDED but the ratio SHRINKS to 1.19x by t32 (Linux
  service rises as it loads the device via depth).  vdev-queue sync-write depth <1 mean, max_active=10
  cap NEVER hit, zl_parallel decay 1-7% (issuer intends to aggregate).  => the throttle is DEPTH, and
  depth is emergent from recycle timing, not a governor limit.

## STEP 2 - LOCALIZATION (probe 0042 RESULT ZILCOMMIT, 0043 RESULT ZILWAKE2): the recycle loop
- committers_max = 1 at ALL thread counts: only ONE thread is ever in zil_commit_writer (backends
  serialize on zl_issuer_lock - same single-committer-in-caller model as upstream Linux).
- Aggregation WORKS (itx_per_lwb_mean 6.8->9.5->16.5, wide batches); issue is FAST (c2i 14-65us, async).
- issue_gap ~= 285-310us ~= the lwb round-trip.  Decomposed: device write ~195us + wake2ent
  (flush-wake -> next-committer-entry) 62->77->131us GROWING with threads.  wake2ent is the OSv
  cross-vCPU wake-to-halted-vCPU cost (IPI + VM-exit/entry).  At t32 nearly HALF the recycle is OSv wake.
- Mechanism: single committer issues lwb N async, returns, blocks on its own fdatasync; lwb N+1 issues
  only after N's flush wakes a backend that must be SCHEDULED (wake2ent) to re-enter as next committer.
  Circular: low depth -> few free committers -> slow re-entry -> low depth.  Linux breaks it with cheap
  inline/softirq wakes (fast recycle -> ~13 in flight).  Confirmed: upstream has NO dedicated issuer;
  Linux depth is pure recycle speed on the SAME model.

## STEP 3 - QUALIFY (isolate A/B): OSV_IDLE_SPIN closes the gap (upstream-faithful lever)
OSV_IDLE_SPIN 10000 (default) vs 500000 (idle vCPUs spin before halting so a woken committer catches the
wake in-spin instead of an IPI/VM-exit round-trip):
| thr | wake2ent (10k->500k) | issue_gap (10k->500k) | op/s (10k->500k) | vs Linux |
|-----|----------------------|-----------------------|------------------|----------|
|  8  | 66 -> 31us           | 315 -> 120us          | 11930 -> 28633 (+140%) | > 25000  |
| 16  | 81 -> 48us           | 287 -> 131us          | 18815 -> 40310 (+114%) | > 34500  |
| 32  | 132 -> 73us          | 303 -> 187us          | 30737 -> 48000 (+56%)  | == 45700 |
HONEST mechanism: lwb-depth MEAN barely moved (~1.5 both arms) - the win is RECYCLE SPEED not depth.
The single-committer model recycles ~2.5x faster once the halted-vCPU wake VM-exit is avoided (issues
2x+).  Exactly the parent's loop-input shrink (wake2ent halved).  Write-service floor (~195us) untouched
and not the throttle at these rates.  The pct-window sweep was a proven NULL (fragments lwbs, no
sustained depth/op gain) - confirming this is not a tunable-batch problem.

## STEP 4 - HAMMERDB: NOT RUN (PG-guest seed substrate failure) -> transfer UNVERIFIED
PG18 image built clean (114MB, IDLE_SPIN in kernel), net up, but the one-time ZFS pool SEED failed:
stock seed_copy -> EACCES writing into fresh 0700 ZFS dirs; patched seed_copy (0777) -> guest hangs
mid-copy.  A PG-guest-boot instability on this build, NOT the lever.  Ran out of budget after earlier
substrate fights (root-owned submodule blocking patch re-apply; missing apps/postgres18-musl at pin
5cb1903; wrong openzfs pin -> zfs_file_t; drifted 0032).  See STEP4-HAMMERDB-BLOCKED.md.
=> Do NOT claim M1 closed.  The isolate gap is closed for durable-write concurrency; the TPROC-C verdict
+ spin-sweep + vCPU-util discriminator (harness written, hdb-verdict.sh) remain for a stable seed.

## DELIVERABLE
The lever is an EXISTING knob (OSV_IDLE_SPIN), so the deliverable is "tune/default OSV_IDLE_SPIN for
fsync-concurrent workloads" + this measurement, not a code PR.  No zil.c divergence, no dedicated issuer.
Probes 0041/0042/0043 pushed to gh-fork/bench/writedepth (bench-only, not for master).  The write-service
~1.9x-uncontended residual (lever a) is the next thing IF HammerDB later shows depth/recycle alone
doesn't transfer.

## CORRECTED PREMISES THIS RUN (measurement was the authority)
- "OSv write is ~2x Linux" -> only uncontended (t8); shrinks to 1.19x at t32 (SVC measured, not wrlat).
- "raise write-issue depth / a dedicated issuer" -> WRONG mechanism; depth mean stays ~1.5, the win is
  RECYCLE SPEED via the wake knob; upstream has no dedicated issuer.
- "commit window / cap" -> proven NULL.
- The fix is a SCHEDULER wake lever, not a ZFS change.
