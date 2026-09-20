# Connect latency: 117.3 ms -> 3.98 ms on aarch64. At Linux parity.

2026-09-09, agent d55c4a8f. Box terminated, 0 orphans. Branch `gh-fork wip/forkroot-arm-base`,
head **`5a8e946f0`**, all commits G-signed. Reported on
**#1456 issuecomment-5604720462** (the fork has issues disabled, so it went on the upstream PR).

## The result

    Linux reference (matched geometry+musl)   4.0-4.3 ms connect median
    OSv aarch64 before                     114.8-117.3 ms
    OSv aarch64 + scan fix                  42.6 ms
    OSv aarch64 + large-page sharing         3.98 ms   <- AT/BETTER THAN LINUX

My hypothesis was right: **connect latency IS fork latency.** All movement was in the `startup`
phase; `tcp` and `query` were unchanged to two decimals in every cell.

## Prediction scorecard (recorded in advance, so it can be scored honestly)
- ~100 ms baseline: **reproduced** (114.8).
- Drop toward a 40-65 ms floor with the scan fix: **exact** (42.6).
- "Improves most at high VU": **WRONG.** Flat 2.65-2.76x across concurrency 1/8/32 - a
  constant-factor per-fork win, not a concurrency unlock.
- "16x residual is probably irreducible": **WRONG, and this is the valuable part.**

## The second cause, which I predicted would survive and did not
`OSV_FORK_TIMING` attributed 99.9% of fork to the leaf-PTE walk, 4.44M PTEs, with `flush_tlb_all`
at **zero**. A `shared_buffers` sweep then fit **3.66 + 9.23 ms per 1M PTEs with 0.6% max error** -
and the cause became visible:

**fork split every 2 MB `shared_buffers` large page into 512 4K PTEs** and re-derived, 8192 times per
16 GB, the same "writable, shared in both" answer the large PTE already carried.

Arithmetic checks out: 16 GB / 2 MB = 8,192 large pages = 4,194,304 4K PTEs, against 4,445,585
measured. Sharing the large PTE verbatim: **n_ptes 4,445,585 -> 132,497** (33.6x fewer), and the
linear model predicts 44.7 ms before / 4.9 ms after, matching the measured 42.6 -> 3.98.

Correctness: **28/28 fork tests pass in both arms**, including the shared-write/COW divergence tests.
`>=1s` probes at concurrency 32 fell **1559 -> 96**.

## Three premises of mine corrected
1. `wip/fork-clone-scan` is **8 commits, not 2** (also `mempool.cc` +62, `virtio-blk.cc` +24) - so the
   env-var A/B is the only clean attribution.
2. **Mergeability is not scope** - my merge-tree check could not have shown this.
3. **"Fork cost scales with connection count" does not reproduce.** Window 1 vs 32 identical in both
   arms. The real axes are **resident PTEs and live threads**, not connections. That was a banked
   finding from an earlier arc and it is now void.

## Two bugs that did not appear, and what that means
Neither the silent wedge nor the OOM abort occurred in **~40 boots**, so **no gdb backtrace is owed** -
nothing was wedged. The OOM is plausibly already fixed by `866bc8b6a` (retry reclaim across shrink
passes), which sat unmerged in the scan branch. **That is the third instance today of a bug fixed by
work that already existed and was simply not where it was needed.**

## Honest gaps, stated by the agent
- **HammerDB NOPM was not run**, so the "improves NOPM at high VU" prediction is untested. The connect
  fix may or may not move throughput.
- **aarch64 only.**
- **96 `>=1s` probes remain at concurrency 32**, so something else still stalls under heavy concurrent
  connect. Down from 1559, not eliminated.
