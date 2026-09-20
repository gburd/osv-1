# The "third cause" was NOT a TLB problem at all - measured, 2.21x fork fix

2026-09-07. Agent 5052cc0d measured the fork cost breakdown and demolished both my
hypothesis and its own. This supersedes THIRD-CAUSE-TLB-FLUSH.md and
THIRD-CAUSE-REVISED-SCAN.md's framing.

## The measurement that settles it

rdtsc phase breakdown of `clone_address_space` (OSV_FORK_TIMING=1, smp32, real
PostgreSQL fork):

| phase | kilocycles | ms | share |
|---|---|---|---|
| TOTAL | 141,344 | 45.6 | 100% |
| **ptwalk** | 141,086 | 45.5 | **99.8%** |
| ranges setup | 201 | 0.06 | 0.1% |
| **flush_tlb_all** | **4** | **0.0013** | **0.003%** |

**`flush_tlb_all` costs 1.3 MICROseconds.** The "guest-wide TLB serialization" I
identified as the third cause, briefed as the target, and then re-briefed after an
IPI-broadcast argument, is 0.003% of fork cost. Dead. The agent's own broadcast
theory died to the same instrument.

The real cost: 2,300,347 leaf PTEs x a 695-entry `share_ranges` vector, scanned
linearly per PTE = **~800 million comparisons per fork**.

## The fix and the A/B (one image, only an env var differs)

`wip/fork-clone-scan` @ `9b4ea6578`, G-signed. Sorted + coalesced half-open
intervals with binary search, replacing the per-PTE linear scan.

| K concurrent forks | 1 | 2 | 4 | 8 | 16 | 32 |
|---|---|---|---|---|---|---|
| linear (before) | 146 | 286 | 552 | 1179 | 2322 | 4631 ms |
| bsearch (after) | 79 | 145 | 279 | 550 | 1172 | 2094 ms |

**2.21x fork throughput** (6.9 -> 15.3 forks/s), per-fork **-55%** (144.7 -> 65.4 ms).

The linear arm reproduced the independently-briefed baseline almost exactly
(4631 vs 4743 ms; 144.7 vs ~150 ms/fork), so the comparison is valid.

## Mechanism confirmed, not just a speedup

The discriminator the whole diagnosis rested on - cost rising with vCPU count on an
IDLE guest - collapsed:

| smp | 2 | 8 | 32 | spread |
|---|---|---|---|---|
| linear | 75 | 89 | 138 ms | +84% |
| bsearch | 62 | 62 | 69 ms | **+11%** |

89% of the vCPU-scaling term removed. That confirms the causal chain:
`with_all_threads()` pushes every live thread's stack into `share_ranges`, OSv pins
~2 threads per CPU, and the vector was scanned linearly per PTE.

## The finding that matters most for the project

**`n_threads=658` at smp32.** Far more than 2/CPU - PostgreSQL backends dominate the
range list. So the scan cost scales with **CONNECTION COUNT**, not merely vCPU count:
fork got more expensive the more backends existed. That reframes it from an SMP
scaling nit into "a fork cost that grows with database concurrency", which is exactly
the regime this program cares about. Asked the agent to quantify fork cost at 8 vs 64
vs 256 live backends at fixed vCPU count so we can state the scaling law honestly.

## Correctness argument

The change alters only HOW the "is this VA in the set?" predicate is computed - not
which VAs are selected, no PTE value, no lock, no flush semantics. Sorted, coalesced,
half-open intervals; identical predicate.

## Also touched (legitimately)

The commit includes the `0031` hunk-header correction
(`-100,6 +100,14` -> `-100,5 +100,15`), without which the tree does not build. A
maintenance agent independently verified that as the correct fix. Incidental build
prerequisite; to be called out in the PR body.

## Still open

- The remaining ~62 ms/fork floor is NOT the scan (it is now flat vs vCPU count). To
  be characterised, not fixed: likely intermediate-table alloc/memset in
  `clone_pt_level<1>/<2>` or the per-PTE write-protect stores. "Here is what fork on a
  2.3M-PTE address space costs" is a useful finding in itself.
- The p99 gate will likely still FAIL: 65 ms/fork x 32 concurrent is ~2.1 s, so a
  fresh-connect probe at VU32 can still exceed 5 s. That is expected and must be
  reported as the residual floor, NOT as the fix underdelivering. The honest headline
  is 2.21x fork throughput with the vCPU-scaling term eliminated.
- **The safety finding stands separately and is worth more than the perf work:**
  `libc/signal.cc` puts a new handler thread into a LIVE fork child's AS, and
  `sched.cc` makes threads inherit their creator's AS, so two CPUs can share one CR3.
  That makes any local-only TLB flush unsound, and puts the existing
  `exception_depth >= 2` local-flush path on an invariant that can be violated.
  Latent memory-corruption risk.

## My error, and the guard

I built a three-cause narrative in which the third cause was a TLB serialization, and
briefed two agents on it. It was 0.003% of the cost. I never did the
order-of-magnitude check that would have refuted it in one line (a 32-way IPI round is
tens of microseconds; the symptom was 150 ms - a 1000x mismatch).

Guard now in force: before briefing a mechanism as a target, state its expected
magnitude and compare it to the measurement. If they differ by orders of magnitude,
the mechanism is wrong, no matter how good the story is.

Third premise of mine corrected today; this one by direct measurement rather than
argument, which is the strongest form.
