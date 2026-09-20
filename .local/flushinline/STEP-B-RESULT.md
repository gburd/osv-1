# STEP B — isolate A/B result: OSV_ZIL_FLUSH_INLINE (inline flush completion)

Box: m5d.metal i-00bce9be7b8f34a9f, Debian 12, qemu 7.2.22, KVM.
Guest: 32 vCPU / 32 GiB, virtio-blk num-queues=8, OSV_BLK_MQ_COMPLETE=1.
Backing store (BOTH arms, symmetric): raw instance-store NVMe /dev/nvme0n1
passed straight through, `-drive format=raw,cache=none,aio=native`. No host-FS
raw file, no host page cache -> the guest FLUSH goes straight to the device
cache-flush, not a host XFS fsync. The A/B differs ONLY in the env flag.
Branch: gh-fork/bench/flushinline (base 7e297fbc2 + 0040 inline-flush).
bench-base-gate: PASS (all required fixes incl #1509 per-queue completion).

## The branch FIRED (Check 1 — the A/B is valid, not a no-op)
inline=0 (OFF): inline_fires=0     dispatch_fires=75943   (all flushes -> taskq)
inline=1 (ON):  inline_fires=75788 dispatch_fires=0       (all flushes -> inline)
100% coverage each arm. The env gate resolved and printed correctly both runs.

## The full A/B sweep (3 reps, 30s each, medians)
| thr | whole_lwblat off->on | op/s off->on          | p50 us off->on | inflight_max off->on |
|-----|----------------------|-----------------------|----------------|----------------------|
|  8  | 427.0 -> 401.8 us    | 11907 -> 12476 (+4.8%)| 609.6 -> 586.5 | 6 -> 6               |
| 16  | 447.3 -> 452.4 us    | 19269 -> 18202 (-5.5%)| 726.9 -> 795.0 | 10 -> 8              |
| 32  | 411.7 -> 446.6 us    | 31063 -> 26546 (-14.5%)| 909.6 -> 1058.5| 16 -> 18            |
(est_flush = whole - write is NOISY: write itself is 277-320us mean with
>100ms max spikes, and whole_lwblat is ZFS's smoothed running average
zl_last_lwb_latency, not a raw per-lwb time. Use whole_lwblat + op/s, which
are unambiguous, as the signal.)

## THE DECISIVE NUMBER — the inline completion pipeline is only 38us
inline_path_us_mean = 38.5 us  (inline_path_us_max = 12.5 ms tail).
That is the ENTIRE cost of the flush completion work measured directly on the
blk thread: child flush zio_execute -> parent lwb_root_zio -> zil_lwb_flush_
vdevs_done -> zl_lock + zl_lwb_io_lock + cv_broadcast fan-out. Everything after
the bio completes. Removing the two INTERRUPT-taskq hops (the whole point of
the fix) therefore cannot be worth ~100us: the work it would have hopped to is
38us, and most of that 38us (the lock + cv_broadcast) still runs regardless.

## VERDICT: the taskq-hop hypothesis is REFUTED on its own terms.
The fix fired on 100% of flushes and did NOT materially drop whole_lwblat or
raise op/s (flat at t8, negative at t16/t32). The ~100-150us "flush" residual
in the M1 table is NOT the two serial taskq hops. STEP C is gated on the flush
dropping; it did not; DO NOT run HammerDB on this fix.

## Where the cost actually is (so the next lever is aimed right)
1. The completion *pipeline* is 38us, not 100us. The taskq hop is a small part.
2. whole_lwblat ~450us is dominated by the WRITE portion (~300us mean, with
   fat tails to >100ms). WRITE (~2x vs Linux in the M1 table) and DEPTH
   (Linux pipelines 14x deeper) are the real OSv-side levers, exactly as the
   decomposition warned; FLUSH was the cheapest-looking but is not a hop cost.
3. The remaining candidate for a per-flush latency win is the IRQ -> blk-
   completion-thread WAKE latency that happens BEFORE zio_interrupt is even
   called (a cross-vCPU scheduler wake, ~tens of us). That is upstream of my
   patch and my patch does not touch it. It is testable by timing virtio-blk
   bio-submit -> bio_done, which #1509 (per-queue completion, already
   default-on) partly addresses. This is NOT the taskq hop.

## Caveat on one probe
RESULT ZILFLUSHRT flush_rt_us_* is INVALID (reads billions): lwb_flush_issued_ns
races with zil_lwb_flush_defer (a flush issued for one lwb completes a merged
tree of others), so the per-lwb stamp/read is not paired. Ignore flush_rt_*;
the fire counters and inline_path_us_mean are correct.
