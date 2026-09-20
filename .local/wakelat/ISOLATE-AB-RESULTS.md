# ISOLATE A/B — MEASURED, first design REFUTED

## Box i-016e19e060a57409f (m5d.metal, lava, qemu 7.2.22 host / 8.1.3 container, halt_poll_ns=200000)
## syncwrite-mt, 32 threads, 30s x 3 reps, ZFS on raw /dev/nvme1n1. All MEASURED.

## RESULT v2 (JUMP-to-cap on catch, HALVE after 4 consecutive halts, floor=256, cap=100000) — WINS
| metric              | FIXED-10000 | ADAPTIVE v2 | verdict              |
|---------------------|-------------|-------------|----------------------|
| syncwrite op/s med  | 27200       | 44841       | ADAPTIVE +65% BETTER |
| wake2ent_us mean    | 137         | 77.7        | -43% (best)          |
| p50 us              | 1019        | 646         | BETTER               |
| p99 us              | 3484        | 2118        | -39% (best)          |
| halt_exits/s        | 41913       | 11039       | 4x FEWER VM-exits    |
adaptive-v2 reps=[44602,44841,46176]. v2 matches best fixed cap (100000->45063) AUTOMATICALLY, no knob,
AND has the lowest halt rate of every arm. p99 IMPROVED. See RESULT.md for the full verdict.

## RESULT v1 (grow x2 on catch, shrink /2 on halt, floor=256, cap=10000) — REFUTED
| metric              | FIXED-10000 | ADAPTIVE v1 | verdict         |
|---------------------|-------------|-------------|-----------------|
| syncwrite op/s med  | 27200       | 15868       | ADAPTIVE -42% WORSE |
| wake2ent_us mean    | 137         | 274         | 2x WORSE        |
| p50 us              | 1019        | 1788        | WORSE           |
| p99 us              | 3484        | 6269        | WORSE           |
| halt_exits/s        | 41913       | 86943       | 2x MORE halts   |

fixed reps=[26056,27200,28744] ; adaptive reps=[15586,15868,16140]

## VERDICT: adaptive v1 is REFUTED on the busy isolate — the OPPOSITE of the goal.
More halt_exits, worse wake2ent, lower op/s. The fixed-10000 (with wake-pull) is
already the better arm here.

## ROOT CAUSE of the regression (diagnosis)
On a heavily-contended ZIL workload every vCPU enters do_idle constantly. My
shrink-on-halt (window/=2 toward floor 256) decays the window fast: a single
halt drops it, and grow (x2 from ~256) can't keep it wide against constant
halts. The window oscillates LOW, so the CPU spends LESS time in idle_poll than
the fixed 10000 -> send_wakeup_ipi suppresses fewer IPIs -> MORE halt_exits ->
worse wake2ent. i.e. adaptive spends less time polled than the fixed baseline,
which is backwards.

## Design fix to try (v2)
The fixed-10000 baseline is strong BECAUSE it stays polled ~10000 iters every
idle entry. To beat it on the busy path AND not regress idle, adaptive must:
  - GROW toward cap FAST and aggressively on a caught wake (jump to cap, or +big
    step, not just x2 from a decayed floor), and
  - SHRINK SLOWLY (only after several consecutive genuine halts), not on every
    single halt, so a busy CPU that occasionally halts does NOT collapse to floor.
Linux halt-poll: grow only when poll FAILED-but-would-have-succeeded-longer;
shrink only after a clean halt with block_ns beyond threshold. The asymmetry
matters: fast-grow / slow-shrink. v1 had symmetric x2 // /2 which loses to fixed.

## Honesty note
This is a MEASURED refutation of adaptive-v1. Not "fixed". Iterating on v2, then
re-measuring. If v2 also cannot beat fixed-10000 on busy without idle regression,
the honest result is: fixed-10000 + wake-pull is the better control and adaptive
does not help here (a valid measured negative).

## FIXED-CAP SWEEP (confirms the higher-spin win exists on THIS box; drives v2 cap)
OSV_IDLE_SPIN_ADAPTIVE=0 (fixed), OSV_IDLE_SPIN=N, 32 threads, 30s x 3:
| OSV_IDLE_SPIN | op/s median | wake2ent_us mean | vs 10000 |
|---------------|-------------|------------------|----------|
| 10000         | 27200       | 137              | baseline |
| 50000         | 42056       | 79.6             | +55%     |
| 100000        | 45063       | 80.7             | +66%     |
Plateau ~50-100k. This IS #1501's +56-140% (higher spin catches more wakes ->
fewer IPI/VM-exit). CONCLUSION: the busy win needs a spin FAR above the old
10000 default. So adaptive must (a) grow to a HIGH cap on busy (cap default
raised 10000 -> 100000), and (b) shrink to the floor on idle. v1 capped at
10000 so it could never reach the win -- and its symmetric decay made it worse
than even fixed-10000. v2: JUMP-to-cap on caught wake, HALVE only after 4
consecutive genuine halts, cap=100000, floor=256.
