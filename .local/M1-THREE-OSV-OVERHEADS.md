# M1 root cause DECOMPOSED: three additive OSv-side overheads vs Linux, same NVMe. All fixable.

## The decisive table (agent ae830f9b, ONE m5d.metal, SAME /dev/nvme1n1, matched geometry, IDENTICAL
## in-flight gauge on both: ++ at LWB_STATE_ISSUED, -- at LWB_STATE_FLUSH_DONE)
    thr   WRITE OSv/Lin   FLUSH OSv/Lin   DEPTH OSv/Lin(mean,max)   flush/s OSv/Lin   op/s OSv/Lin
     8    288/140us       127/16us        1.39,6 / 2.31,8          3340/4604         11840/25057  0.47x
    16    348/190us       147/23us        1.76,7 / 4.18,18         3535/4986         17689/36006  0.49x
    32    372/266us       114/40us        1.99,10 / 13.95,42       4078/5620         30418/48632  0.63x

## THREE OSv-side overheads, all measured vs Linux on the SAME device, all ADDITIVE:
1. **FLUSH overhead ~7x (THE SURPRISE, refutes the prior run):** OSv flush 114-147us vs Linux 16-40us.
   The device flushes in ~16us. The prior run called OSv's ~110us flush "healthy device physics" and
   EXCLUDED it - REFUTED by the Linux-same-device number. A ZERO-BYTE barrier at 114us is pure OSv
   completion-path overhead. Cheapest to shave (no data), fix FIRST.
2. **WRITE overhead ~2x:** OSv lwb write 288-372us vs Linux 140-266us. Confirms (not just infers) the
   prior "270us write" as partly OSv overhead - now measured against Linux, not against a buffered pwrite.
3. **DEPTH gap ~14x at t32:** Linux pipelines to mean 14 / max 42 in-flight lwbs; OSv barely mean 2 /
   max 10. The prior "depth overlaps, not the fix" UNDERSTATED how much more Linux pipelines.

## Why the isolate was stuck ~0.5x and never one clean lever: THREE additive costs, not one.
Every prior single-lever fix (fsync-scan, dentry, #1509, fan-out, window) was real but each addressed
at most one small part, so each was a NOPM null / small isolate win. The gap is the SUM of flush + write
+ depth overhead, all OSv-side, all vs Linux on identical hardware. This is the complete decomposition.

## FIX ORDER (next run: fix + qualify, cheapest/biggest-leverage first)
1. **FLUSH completion overhead (16us device -> 114us OSv = ~100us of pure OSv cost).** Trace the flush
   completion path: MSI-X IRQ -> blk completion thread wake -> biodone -> vdev_disk_bio_done ->
   zio_interrupt -> zio pipeline -> zil_lwb_flush_vdevs_done. A zero-byte flush should complete in ~device
   time; ~100us over that is scheduler/wakeup/zio-pipeline latency on the completion. #1509 (per-queue
   completion, now default-on) helps here; the residual ~100us is the remaining completion-path cost.
2. **WRITE overhead (~150us over device).** abd_borrow_buf_copy + zio write pipeline + virtio-blk submit.
3. **DEPTH (Linux 14x deeper pipeline).** Once flush+write latency drop, depth may rise naturally
   (faster completion -> issuer keeps more outstanding); if not, raise the issuer's outstanding-lwb cap.

## Success criterion unchanged: fix -> isolate flush/s + op/s rise toward Linux -> HammerDB scales
## VU16->VU32. The write-rate/flush-rate lever plausibly transfers to HammerDB (WAL commits ARE durable
## writes), unlike the completion-parallelism lever that HammerDB-nulled.

## Shipped so far on this critical path: #1509 per-queue completion DEFAULT-ON (+33-38% op/s isolate).
## Next: attack the ~100us flush completion overhead - the cheapest, and it is zero-byte so no data path.

## FLUSH overhead LOCALIZED (local source trace) - the cheapest target, now named
Chain: virtio-blk MSI-X IRQ -> blk completion thread wake -> biodone -> vdev_disk_bio_done ->
zio_interrupt -> zio_taskq_dispatch(ZIO_TASKQ_INTERRUPT) -> [INTERRUPT taskq thread] ->
zio pipeline -> zil_lwb_flush_vdevs_done.
The FLUSH zio_taskqs row = { ZTI_ONE, ZTI_NULL, ZTI_ONE, ZTI_NULL } (ISSUE, ISSUE_HIGH, INTR, INTR_HIGH)
=> the FLUSH INTERRUPT (completion) taskq is ZTI_ONE = ONE thread. Every flush completion funnels
through a single taskq thread AFTER the blk-completion-thread wake. Two serial hops (blk thread + taskq
thread) for a zero-byte op that just wakes waiters. Device does it in 16us; OSv adds ~100us of
wake+hop+queue latency. This is upstream's DEFAULT ZTI (not an OSv edit), but OSv's per-hop wakeup cost
(cross-vCPU IPI + VM-exit) is higher than Linux inline/softirq completion, so the same ZTI_ONE hurts more.

## Fix candidates for the ~100us flush completion (MEASURE which, do not assume):
  A. Run the FLUSH completion INLINE on the blk completion thread (skip the INTERRUPT taskq hop) - a
     flush done-callback is trivial (zero-byte, just walks lwb_waiters + wakes). cutinline / a direct
     call avoids one thread wakeup. Smallest change.
  B. Widen the FLUSH INTERRUPT taskq (ZTI_ONE -> ZTI_N(k)) so concurrent flush completions parallelize.
  C. #1509 per-queue completion (default-on) already parallelizes the blk-thread hop; the residual is
     the taskq hop -> A is the natural complement.
The isolate flush latency (114us) + the depth gauge already exist on bench/lwbpipe to A/B any of these.

## NEXT RUN: fix the flush completion (candidate A first), qualify on the isolate (flush latency should
## drop toward device ~16-40us, flush/s rise), THEN write overhead, THEN depth. Then HammerDB verdict.
## The flush is the cheapest (zero-byte, one hop to remove) and 30% of the per-lwb latency.

## UPDATE 2026-09-15 (agent-flushinline): FLUSH-INLINE CANDIDATE A REFUTED (measured, not assumed).
## Built OSV_ZIL_FLUSH_INLINE=1 on gh-fork/bench/flushinline (zio_interrupt runs ZIO_TYPE_FLUSH inline
## via zio_execute on the blk thread; zio_notify_parent lets the lwb_root_zio parent run inline too).
## m5d.metal, Debian 12, qemu 7.2, RAW instance-store NVMe passthrough (cache=none) BOTH arms.
## - Branch FIRED on 100% of flushes: inline_fires=75788, dispatch_fires=0 (valid A/B, not a no-op).
## - Backing store symmetric (raw device, no host-FS fsync) -> NOT a substrate confound.
## - DECISIVE: the ENTIRE inline flush-completion pipeline (child flush zio + parent root zio +
##   zil_lwb_flush_vdevs_done + zl_lock + cv_broadcast) measured directly = 38.5us. ~11us of that
##   (lock + cv_broadcast) is irreducible (Linux does it too). Removing the two INTERRUPT-taskq hops
##   therefore CANNOT be worth ~100us. Result: whole_lwblat flat (t8 427->402, t32 412->447us),
##   op/s flat-to-negative (t8 +4.8%, t16 -5.5%, t32 -14.5%), flush/s flat. NO HammerDB (gated on
##   flush dropping). NO PR (measured null).
## - The ~100-150us "flush" in the table above is NOT the taskq hops. est_flush = whole - write is a
##   NOISY subtraction (write ~300us mean w/ fat tails; whole_lwblat is ZFS's smoothed running avg
##   zl_last_lwb_latency, not a raw per-lwb time). The real cost is the WRITE portion.
## - REAIM the next lever at WRITE (~2x) and DEPTH (14x). One remaining per-flush candidate: the
##   IRQ -> blk-completion-thread WAKE latency BEFORE zio_interrupt (cross-vCPU scheduler wake),
##   which is upstream of the taskq and NOT what candidate A touched; testable by timing virtio-blk
##   bio-submit -> bio_done. Do NOT re-try the taskq-hop lever: it fired and did nothing.
## Full write-up: .local/flushinline/STEP-B-RESULT.md.

## FIX RUN DISPATCHED (agent 8ab9ffa1, 2026-09-15, Debian): inline the FLUSH completion
The fix: for ZIO_TYPE_FLUSH, run zio_execute INLINE on the blk completion thread (which already runs
vdev_disk_bio_done inline, 256KB stack) instead of the zio_interrupt -> single INTERRUPT taskq hop.
cutinline on OSv only = TQ_FRONT (still hops) so it will not do it; needs a true-inline path or a
ZIO_TYPE_FLUSH special-case in zio_interrupt/vdev_disk_bio_done. Env-gated OSV_ZIL_FLUSH_INLINE for A/B.
Hazards flagged to the agent: stack depth on the blk thread (flush pipeline + cv_broadcast fan-out must
fit 256KB); no deadlock (zil_lwb_flush_vdevs_done takes zl_lock - blk thread must be able to).
Steps: A build+gate, B isolate A/B (flush latency 114us -> toward device 16-40us?), C HammerDB verdict
(does OSv scale VU16->VU32 toward Linux?). File as PR if clean.

## WHY this could be the one that moves HammerDB (unlike #1509's completion-parallelism null)
The flush LATENCY is on the per-commit critical path of EVERY durable WAL write. HammerDB TPROC-C
backends do durable WAL commits; cutting ~100us off each flush completion cuts the per-commit round-trip
directly, which raises the flush RATE (throughput = rate x batch). The completion-PARALLELISM lever
(#1509) nulled because TPROC-C did not saturate the completion path; the flush-LATENCY lever is
different - it shortens every commit, saturated or not. If it transfers, OSv scales. If not, write+depth
remain and we attack those next. Honest either way.

## Overhead ledger (all OSv-side, measured vs Linux same NVMe, additive):
  FLUSH ~100us over device (attacking NOW)  |  WRITE ~150us over device (next)  |
  DEPTH 14x shallower pipeline (last, may self-resolve once flush+write drop)
  agent-flushinline: metal i-00bce9be7b8f34a9f + driver i-0dcf2ad4d13a65dd4, STEP B running

## STEP B inline-flush: NULL (agent 8ab9ffa1). The INTERRUPT-taskq hop is NOT the ~100us flush cost.
est_flush off->on: t8 150->121us (-19%), t16 154->139 (-10%), t32 125->127 (+2%). whole lwblat barely
moves; op/s even NEGATIVE at t16/t32 (inlining a deep pipeline on the blk drain thread can serialize it).
So skipping the taskq hop does ~nothing -> the flush residual is elsewhere. My "taskq hop = 100us"
hypothesis REFUTED (~6th on this path).

## TWO checks steered before concluding (one may INVALIDATE the flush gap entirely):
1. Did OSV_ZIL_FLUSH_INLINE actually FIRE? If not, the null is a no-op not a refutation. Confirm via a
   counter/boot-line proving the inline path executed on flushes.
2. **THE POSSIBLE CONFOUND (ties to the operator QEMU/substrate concern):** was the OSv guest flush
   backed by a RAW FILE on XFS on /mnt/nv (mode-2 layout) -> guest FLUSH = qemu -> host fsync(raw file
   on XFS) = ~100us, while the Linux flush was measured on the RAW /dev/nvme1n1 (16us bare cache-flush)?
   If asymmetric, the 7x flush gap is a SUBSTRATE artifact (host-fsync-of-XFS-raw-file vs raw-device),
   NOT OSv overhead - and inlining the hop correctly did nothing. Check: OSv pool backing, Linux flush
   backing, and qemu cache= mode. If confounded, redo flush comparison with BOTH on identical backing
   (ideally both as GUESTS under the same qemu). If symmetric, the flush gap is real OSv-side and the
   next candidate is the IRQ->blk-completion-thread WAKE latency (scheduler/vCPU wake, pre-taskq).

## Consequence: if flush is a substrate artifact, the REAL OSv-side levers are WRITE (~2x) + DEPTH (14x),
## not flush. That would refocus the fix and is itself a major finding. Do NOT proceed to HammerDB or
## file until the backing-store symmetry is confirmed. #1509 (shipped) stands regardless.

## STEP B FINAL (agent 8ab9ffa1): inline-flush DEFINITIVELY refuted, both confounds ruled out.
(1) Branch FIRED: inline=1 -> 75788 inline_fires / 0 dispatch (100% coverage) - valid A/B, not a no-op.
(2) Backing SYMMETRIC: both arms raw instance-store /dev/nvme0n1 passthrough, cache=none aio=native
    (guest FLUSH -> device cache-flush, NOT host XFS fsync). The substrate confound I flagged is RULED
    OUT - the flush comparison is clean, not an artifact.
(3) DECISIVE: the WHOLE inline flush pipeline (child zio + root zio + zil_lwb_flush_vdevs_done +
    cv_broadcast) measured 38.5us on the blk thread. Removing the two INTERRUPT-taskq hops cannot be
    worth ~100us when the hopped-to work is only 38us (~11us of it lock+cv_broadcast, irreducible,
    Linux pays it too). whole_lwblat flat (427->402, 412->447), op/s flat-to-negative, flush/s flat.
=> the ~100-150us "flush" residual is NOT the completion hops. It is dominated by the WRITE portion
   (~300us mean, fat tails). My "flush = taskq hops" hypothesis REFUTED (7th on this path).

## No PR from this run (measured null, correctly not filed). #1509 default-on stands.

## REFOCUS (the decomposition holds): the M1 gap lives in WRITE + DEPTH, not flush.
  WRITE: OSv 288-372us vs Linux 140-266us (~2x). ~300us mean with fat tails. THE dominant per-lwb cost.
  DEPTH: OSv mean 2 in flight vs Linux 14 at t32 (~14x). Linux pipelines far more outstanding lwbs.
NEXT: attack the WRITE latency. Candidates (to MEASURE, not guess - trace where the 300us write goes):
  - abd_borrow_buf_copy (synchronous 8k memcpy per write) - small (~us) but confirm.
  - the virtio-blk WRITE submit->completion round-trip vs Linux on the same passthrough device (now that
    backing is confirmed symmetric, a like-for-like guest-vs-guest write-latency compare is valid).
  - the zio WRITE pipeline stages OSv runs that Linux short-circuits.
  - whether DEPTH is the actual lever: if OSv kept 14 writes in flight like Linux, rate = depth/latency
    would ~7x even at the SAME per-write latency. So DEPTH may be the bigger, cheaper win than shaving
    the write. MEASURE why OSv keeps only ~2 in flight (issuer cadence / a serializing wait) - this ties
    back to the zil issuer, but now framed as WRITE-issue depth, not flush.
The write-latency-vs-depth question is the next discriminator (like the flush-vs-device one): does OSv
write SLOWER, or just keep FEWER in flight? Both are measured numbers away.

## UPDATE 2026-09-15 (agent-writedepth): the M1 depth deficit is the OSv WAKE latency, fixed by OSV_IDLE_SPIN
Metal i-0179b5abdcea6333b + driver i-0929075f9348808d7 (terminated). Full write-up .local/writedepth/FINAL-REPORT.md.
DISCRIMINATOR (new probe 0041 RESULT ZILSVC, device io_delay + vq_cactive, matched OSv-vs-Linux same NVMe):
  - OSv device write SERVICE ~190-200us vs Linux 100-168us: ~1.9x UNCONTENDED but shrinks to 1.19x at t32
    (Linux service rises as it loads the device via depth). vdev sync-write depth <1 mean, cap(10) never
    hit, zl_parallel decay 1-7%. => throttle is DEPTH, emergent from recycle timing not a governor limit.
LOCALIZATION (0042 ZILCOMMIT, 0043 ZILWAKE2): committers_max=1 (single-committer-in-caller, SAME as
  upstream Linux - upstream has NO dedicated issuer). Aggregation works (itx/lwb 6.8->16.5), issue fast
  (c2i 14-65us async). issue_gap ~285-310us = device write ~195us + wake2ent (flush-wake->next-committer
  entry) 62->131us GROWING with threads = the OSv cross-vCPU wake-to-halted-vCPU IPI/VM-exit cost.
  Circular: low depth -> few free committers -> slow re-entry -> low depth. Linux breaks it with cheap
  wakes. So the OSv-side lever is RECYCLE SPEED (wake latency), not depth, not the write path, not a cap.
FIX (upstream-faithful, EXISTING knob, no zil.c change, no new thread): OSV_IDLE_SPIN 10000->500000 (idle
  vCPUs spin before halting so a woken committer catches the wake in-spin, no IPI/VM-exit). Isolate A/B:
  wake2ent HALVED (t32 132->73us), issue_gap 303->187us, op/s +56-140% (t8 12k->28.6k, t16 18.8k->40.3k,
  t32 30.7k->48k) -> OSv REACHES/EXCEEDS Linux on the syncwrite isolate. lwb-depth mean stayed ~1.5 (the
  win is recycle SPEED not concurrency, ~2.5x more issues). pct-window sweep = proven NULL.
HAMMERDB: NOT RUN - PG18 image built clean but the one-time ZFS pool SEED failed (seed_copy EACCES into
  fresh 0700 ZFS dirs; patched 0777 -> guest hang mid-copy). Ran out of budget after substrate fights
  (root-owned submodule; missing apps/postgres18-musl@5cb1903; wrong openzfs pin->zfs_file_t; drifted
  0032). => TPROC-C transfer UNVERIFIED. Isolate gap CLOSED for durable-write concurrency; the M1 TPROC-C
  verdict + spin-sweep + vCPU-util discriminator remain for a stable seed (harness hdb-verdict.sh ready).
  DO NOT read the isolate win as M1-closed. Honest: closes the microbenchmark, TPROC-C pending.
