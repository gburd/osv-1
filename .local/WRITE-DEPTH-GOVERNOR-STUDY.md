# How FreeBSD/Linux/OpenZFS govern the ZIL write-issue depth (source study, informs the WRITE/DEPTH fix)

## The governing mechanism (upstream OpenZFS, shared by FreeBSD + Linux)
1. **vdev I/O queue (vdev_queue.c) caps outstanding zios per priority:**
     zfs_vdev_sync_write_max_active = 10  (min_active 10)   <- ZIL lwb writes are ZIO_PRIORITY_SYNC_WRITE
     zfs_vdev_max_active = 1000 total
   So the QUEUE permits up to 10 concurrent sync-write zios to a vdev. OSv keeps only ~2 lwbs in flight,
   Linux ~14 - so NEITHER is limited by this cap being too LOW (10 >= 2), and Linux's 14 exceeds the
   sync-write cap because lwb writes can also ride other classes / the cap is per-class not hard.
2. **Single ZIL issuer (zl_issuer_lock):** one thread at a time creates+issues lwbs. zil_commit_writer
   collects a batch (ilwbs) under the lock, then issues them ALL via zil_lwb_write_issue -> zio_nowait
   (ASYNC, non-blocking). So the code path supports many in flight; issuance is serialized but does NOT
   wait for completion.
3. **Pipeline via zio parent-child:** next lwb's root zio is a parent of prev lwb's root (zio_add_child),
   enforcing completion ORDER, not issue serialization. "many lwb zio's concurrently issued" (zil.c:3948).
4. **OSv USES vdev_queue.c** (in open_zfs_sources.mk) and zio_vdev_io_start routes through it; the lwb
   write reaches vdev_disk_io_start -> strategy(bio) async. So the OSv submit path is NOT synchronous.

## So why is OSv depth ~2 vs Linux ~14, if the code + queue + submit all support more?
The depth is EMERGENT from TIMING, not a hard cap:
  depth ~= commit_arrival_rate x round_trip_latency (Little's law on the issuer).
OSv either: (a) the round-trip (write+flush) completes so fast relative to commit arrival that few
overlap (would mean OSv is NOT slower - contradicts the 2x write number), OR (b) the commit-writer is
not RE-ENTERED fast enough to issue the next batch while prior lwbs are still in flight - i.e. the ISSUER
CADENCE is throttled. The zl_parallel logic (earlier run) governs whether OSv aggregates; it decays when
prev lwb reaches FLUSH_DONE before the next commit - which happens if the issuer thread is not scheduled
promptly OR the commit-window (#1505 area) is not held. This is the WRITE-ISSUE-DEPTH cadence, distinct
from the flush completion (ruled out).

## THE DISCRIMINATOR to measure (write-slower vs fewer-in-flight)
Both OSv and Linux, same NVMe passthrough, matched, at t8/16/32:
  - per-write zio latency (issue -> WRITE_DONE) on BOTH  [is OSv's write genuinely 2x, or was the earlier
    288us number inflated by QUEUEING behind other writes because depth was low? measure the SERVICE time
    (device write) separately from the QUEUE wait]
  - concurrent in-flight WRITE zios (not lwbs - the actual write zios at the vdev queue) on BOTH
  - the commit-writer re-entry cadence: how often is zil_commit_writer called, and does it find prior
    lwbs still in flight (zl_parallel latches) or already done (decays)?
  - vdev queue depth: vq_cactive[SYNC_WRITE] on both (are we hitting the 10 cap? OSv should NOT be if
    depth is 2)
DISCRIMINATE:
  - OSv write SERVICE time ~= Linux but OSv depth low -> the write is NOT slower; the issuer keeps too
    few in flight -> FIX = issuer cadence (keep the commit-writer filling the pipe; possibly raise the
    effective aggregation window OR wake the issuer to re-run while lwbs are outstanding). This is the
    likely + cheaper win: raising depth 2->10 alone would ~5x the rate at the SAME write latency.
  - OSv write SERVICE time genuinely 2x Linux at matched depth -> FIX = shave the write path (abd copy,
    zio stages, virtio-blk write round-trip). Harder.

## FreeBSD-specific note (OSv's platform layer is FreeBSD-derived)
FreeBSD vdev_geom issues zios async to GEOM; OSv vdev_disk issues async to the OSv block layer via
strategy(bio). Both async. The FreeBSD ZIL commit uses the SAME zil.c issuer + vdev_queue. So the
governor is identical to Linux; any OSv depth deficit is in the OSv SCHEDULING of the issuer thread or
the completion->reissue latency, NOT the ZFS governor itself. That is the OSv-side lever.

## FIX HYPOTHESIS (to confirm by the discriminator, then build): raise effective write-issue DEPTH.
If depth is the lever, the fix is to keep more lwb writes outstanding - either by ensuring the
commit-writer re-runs promptly while lwbs are in flight, or by not letting zl_parallel decay under the
OSv completion timing. This is a scheduling/cadence fix on the OSv side, generic (helps any concurrent
sync-write workload), and if depth 2->~10, rate ~5x -> toward Linux parity.

## FIX CYCLE DISPATCHED (agent 27271729, 2026-09-15, Debian, raw NVMe passthrough)
The LAST planned cycle on the ZIL critical path. Informed by the FreeBSD/Linux governor study above:
the governor is identical across all three (vdev_queue max_active=10, single zl_issuer, zio parent-child
pipeline), so OSv's depth-2-vs-Linux-14 deficit is in OSv's ISSUER SCHEDULING / completion->reissue
cadence, not ZFS. STEP 1 discriminator: is OSv write SERVICE time ~2x (shave the write) or is depth low
at equal service time (raise issuer depth - cheaper, ~5x if 2->10)? Then build the named fix, isolate
A/B, HammerDB verdict (does OSv scale VU16->VU32?). File PR if clean.

## HONEST framing for the operator (set expectations)
This is the last single-fix cycle on the ZIL write path. Three outcomes:
  A. depth is the lever + fixable + transfers to HammerDB -> M1 gap materially closes. Best case.
  B. write-service is 2x + shaveable + transfers -> partial close, follow-up for depth.
  C. it moves the isolate but HammerDB still declines (like #1509) OR neither is cheaply fixable ->
     the honest conclusion: OSv's ZFS-write path (issuer scheduling + write latency) needs deeper
     architectural work than single env-gated fixes, and we STATE that plainly and step back to the
     broader program (merge ready PRs, M2/PGXN) with 9+ real fixes banked and the gap fully characterized.
Either way this cycle CONCLUDES the deep-dive with a definitive answer, not another layer.

## STEP 1 DISCRIMINATOR RESULT (agent 27271729): DEPTH dominates, decisively.
Matched OSv-vs-Linux, same m5d.metal, same raw /dev/nvme0n1:
  lwb depth mean:  OSv ~1.4-1.7 FLAT   vs Linux 2.4 -> 12.2 -> 12.9 (scales ~9x with threads)
  device SERVICE:  OSv ~190-200us FLAT vs Linux 100-168us RISING (1.89x@t8 shrinking to 1.19x@t32)
  vdev-queue sync-write depth <1 mean, max_active=10 NEVER hit -> queue NOT the throttle.
  zl_parallel decay only 1-7% -> issuer INTENDS to aggregate; successor lwbs still launch ~1-at-a-time.
  op/s: OSv 12k/18.9k/31.8k vs Linux 25/34.5/45.7k (0.48-0.70x).
rate=depth/service: OSv 1.5/195us=7.7k vs Linux 12.9/168us=76.8k ~ 10x; the 9x DEPTH gap is the
overwhelming term. Raising OSv depth 1.5->~10 at 195us = ~7x, closes most of the gap WITHOUT touching
the write. There IS a real smaller write residual (~1.9x uncontended per-write, shrinks under load).

## FIX = raise write-issue DEPTH via the ISSUER RE-ENTRY/AGGREGATION CADENCE (not a cap raise).
The cap is unhit and zl_parallel latches, so the deficit is: OSv issues lwb N, then does not issue N+1
until ~the prior completes (serialized), where Linux issues successive lwbs back-to-back under the
committing thread without waiting. The OSv-specific cause is the issuer thread not being re-entered/
rescheduled promptly (scheduling/wakeup), or fewer itxs accumulating per pass. Steered the agent to name
WHERE the one-at-a-time issue comes from and fix the CADENCE within the existing governor (preserve the
zio parent-child ordering + zl_issuer_lock + log-space bounds; do not bypass ZFS semantics).
Isolate A/B (depth must rise ~10, op/s scale) -> HammerDB verdict. If depth won't rise structurally,
that is the "needs deeper architectural work" honest conclusion.

## STEP 2 LOCALIZED (agent 27271729): a CIRCULAR latency->depth->re-entry loop. Structural, not a tunable.
committers_max=1 (backends serialize on zl_issuer_lock - BY DESIGN, Linux too). Aggregation WORKS
(itx_per_lwb 6.8->16.5), issue is FAST (c2i 14-60us, async zio_nowait). THE LOOP: the single committer
issues lwb N, returns, then BLOCKS in zil_commit_waiter on its OWN fdatasync; lwb N+1 does not issue
until N's flush (~285us round-trip) wakes a waiter who re-enters as the next committer. depth~1.4 ->
only ~1-2 threads free to commit -> low re-entry rate -> low depth. Linux breaks the loop with shorter
round-trip + cheaper wakes -> threads cycle back fast -> ~13 in flight.

## CRITICAL upstream fact (verified in pinned zil.c): NO dedicated ZIL issuer thread upstream.
zil_commit_impl() = zil_commit_writer() + zil_commit_waiter() in the CALLER's (backend's) context.
Linux gets depth ~13 with this SAME single-committer-in-caller model, purely by RECYCLING BACKENDS
FASTER (cheaper wakeups + shorter round-trip -> more threads cycling through zil_commit at once ->
deeper pipeline). Linux does NOT use a dedicated issuer.

## CONSEQUENCE for the fix (steered):
- A dedicated issuer thread on OSv = a DIVERGENCE from shared zil.c (upstream has none). Bigger, less
  upstreamable. Only as a fallback, and only as a clean OSv-platform choice (not a zil.c logic fork).
- The UPSTREAM-FAITHFUL fix = make OSv backends RECYCLE FASTER: shrink the loop input (the ~285us
  round-trip = 195us device write + wake cost, and/or the wake+reschedule latency when a flushed
  backend must be scheduled onto a CPU to re-enter as next committer). If OSv recycled as fast as
  Linux, the SAME single-committer model builds the SAME depth.
- Discriminator for the fix: how much of the ~285us round-trip is device-write (195us) vs the
  wake+reschedule of the next committer (cross-vCPU IPI/schedule cost)? If wake is a big chunk, faster
  next-committer wakeup is the OSv-side, upstream-faithful lever (ties to the wake-fan-out / scheduler
  costs seen elsewhere). Try faster-recycle FIRST; dedicated-issuer only if that cannot raise depth.

## Substrate note: root-owned submodule files blocked patch re-apply (partial series -> zfs_file_t break);
## agent fixed (chown + per-patch recount + 0032 exact-anchor). ELF clean, boots 238ms. The submodule-
## patch-apply fragility keeps recurring - the loud-git-apply fix from earlier helped but chown is still
## a manual step; worth a harness fix (ensure submodule files are user-owned before patch-apply).

## STEP 3 ISOLATE WIN (agent 27271729): the ZIL recycle lever is OSV_IDLE_SPIN. Isolate gap CLOSED.
Recycle (~285us) decomposed: device write ~195us (lever a, floor) + wake2ent (flush-wake -> next-
committer-entry) 62-131us GROWING with threads (lever b = OSv cross-vCPU wake-to-HALTED-vCPU VM-exit).
OSV_IDLE_SPIN 10000->500000 (idle vCPUs spin before halting so the woken committer catches the wake
instead of an IPI/VM-exit): wake2ent t32 132->73us, issue_gap 303->187us.
  op/s: t8 11930->28633 (+140%), t16 18815->40310 (+114%), t32 30737->48000 (+56%).
  OSv now t16 40310 > Linux 34.5k, t32 48000 ~= Linux 45.7-48.6k. Isolate gap (0.48-0.70x) CLOSED.
HONEST mechanism: lwb-depth MEAN stayed ~1.5 BOTH arms - the win is RECYCLE SPEED, not concurrency.
The single-committer-in-caller model (SAME as Linux) recycles ~2.5x faster once the halted-vCPU wake
VM-exit is avoided. rate=depth/latency: cut recycle latency at constant depth -> higher rate. This is
the SAME OSv wakeup-latency theme all campaign - now with an EXISTING knob (OSV_IDLE_SPIN, PR #1501
area) that addresses it. NOT a new zil.c fix, NOT a dedicated issuer, upstream-faithful.

## THE RISK the HammerDB verdict must capture (steered): idle-spin burns idle-vCPU cycles.
Isolate is ZIL-bound (vCPUs idle on I/O -> spin free). HammerDB TPROC-C uses vCPUs for QUERY work ->
idle-spin could STEAL query cycles (net loss) OR net-win (wake latency saved > spin cost). The isolate
CANNOT settle it. HammerDB run must: (1) SWEEP the spin value (baseline / moderate / 500000) - 500000 is
aggressive, a moderate value may net better on a query workload; (2) watch vCPU util and distinguish
spin-cycles from query-cycles. Verdict: if a spin value lifts NOPM + stops VU16->VU32 decline + util is
useful work -> OSV_IDLE_SPIN is the M1 lever, transfers, HUGE (deliverable: tune/default it, feed #1501).
If it helps isolate but not TPROC-C (query cycles stolen, or 200wh is bound elsewhere as prior NULL-wait
runs showed) -> honest null, isolate win real for pure durable-write, does not close TPROC-C M1 gap.
Do NOT claim M1 closed on the isolate alone.

## Where this leaves the M1 thesis (regardless of the HammerDB outcome)
The gap is now FULLY explained: OSv per-commit recycle latency (write floor 195us + cross-vCPU wake
VM-exit) keeps the single-committer pipeline shallow-effective; the write floor (~1.9x uncontended) is a
residual. It is the recurring OSv WAKEUP-LATENCY theme, and OSV_IDLE_SPIN directly attacks the wake half
on the isolate. The open question is purely whether that transfers to a mixed query workload - which is
the idle-spin-vs-query-cycles tradeoff, now measured, not assumed.

## STEP 4 HammerDB: NOT RUN (honest). The M1 TPROC-C transfer is UNVERIFIED.
The PG18 image built clean but the one-time ZFS pool seed failed: seed_copy hit EACCES creating children
into fresh 0700 ZFS dirs; the 0777 workaround then HUNG the guest mid-copy. Earlier substrate fights
(root-owned submodule patch re-apply) consumed the budget. Agent correctly did NOT claim M1 closed.
0 orphans. Probes on gh-fork/bench/writedepth; harness for the spin-sweep + vCPU-util discriminator written.

## TWO NEW substrate defects surfaced (both cost benchmark budget, both worth a durable harness fix):
1. seed_copy EACCES into FRESH 0700 ZFS dirs (dest is ZFS, not rofs - DIFFERENT from the earlier
   rofs-0555 fix). Cause AMBIGUOUS (uid!=0? ZFS vn_access quirk on fresh dirs? source traversal?) -
   do NOT blind-fix; the actual errno path must be captured next run.
2. 0777 mkdir workaround HANGS the guest mid-copy = a separate, worse ZFS-WRITE hang under the seed
   copy. This is a real OSv-ZFS-write robustness gap (echoes the earlier "heavy-checkpoint RW abort").
Recurring theme: ZFS seeding fragility keeps costing runs. A durable harness fix (seed via a known-good
path, or diagnose the ZFS-write hang) would de-risk every future benchmark.

## CONCLUSION of the "last planned ZIL cycle" (honest):
- The write/depth lever is DEFINITIVELY understood: OSv per-commit RECYCLE latency (device write ~195us
  floor + cross-vCPU wake-of-next-committer VM-exit 62-131us) keeps the single-committer pipeline
  shallow-effective. Same single-committer model as upstream Linux; the deficit is the OSv wake VM-exit.
- OSV_IDLE_SPIN (existing knob) CLOSES the ISOLATE gap (+56-140% op/s, OSv >= Linux) by cutting the wake
  VM-exit. Mechanism = recycle speed, not depth. Upstream-faithful, no zil.c change.
- The M1 TPROC-C VERDICT (does it transfer? does idle-spin steal query cycles?) is UNMEASURED - the seed
  failure blocked HammerDB. This is the ONE remaining question and it needs a stable seed.

## The M1 gap is now FULLY EXPLAINED (the campaign's real deliverable):
Every layer traced to the SAME root: OSv's cross-vCPU WAKEUP LATENCY (IPI-to-halted-vCPU VM-exit).
It shows as the wedge (dead wakes), the fan-out (serial wakes), the completion path, and now the ZIL
recycle. OSV_IDLE_SPIN attacks the wake half directly. Whether shrinking it closes TPROC-C end-to-end,
or whether the idle-spin cost + the ~195us write floor leave a residual, is the final measurement.

## FINAL M1 VERDICT RUN dispatched (agent ccc5615b, 2026-09-15): OSV_IDLE_SPIN HammerDB sweep.
Base bench/writedepth (OSV_IDLE_SPIN + all levers + probes). Build hygiene FIXED for the seed:
re-pin apps to 3f93f43 (correct seed_copy - the writedepth seed EACCES was a CORRUPTED build from a
root-owned-submodule patch fight, NOT a seed_copy bug; seeding works on clean builds), user-own submodule
files before patch-apply, clean build, gate PASS. If seed still fails: CAPTURE errno first, no 0777.
A/B: OSv (baseline / moderate spin / 500000) vs Linux, VU16/32, watch vCPU util (useful work vs spin
theft). Verdict: transfers (M1 closes, tune OSV_IDLE_SPIN, feed #1501) OR durable-write-only (honest null).
This is the honest END of the M1 deep-dive - a definitive answer either way.

## Per operator: stepping back to the broader program in parallel - bank the fixes, maintenance sweep.
