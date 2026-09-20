# Fork clone-scan fix: results, and why it is NOT a standalone upstream PR

2026-09-07. Agent 5052cc0d. Box i-0476003cf35b4bc3f terminated by me after the agent
exhausted context; 0 orphans, no stray volumes.

## Two commits, both G-signed, preserved on `wip/fork-clone-scan`

    9b4ea6578  mm: fix O(PTEs x threads) range scan in fork page-table clone
    65279b938  mm: memoize the fork clone range lookup (per-PTE cost 65 -> 40 cycles)

## The measurement that killed my hypothesis (and the agent's)

rdtsc phase breakdown of `clone_address_space` (smp32, real PostgreSQL fork):

| phase | ms | share |
|---|---|---|
| ptwalk | 45.5 | **99.8%** |
| ranges setup | 0.06 | 0.1% |
| **flush_tlb_all** | **0.0013** | **0.003%** |

`flush_tlb_all` is 1.3 MICROseconds. My "guest-wide TLB serialization" third cause was
0.003% of the cost. The real cost: 2,300,347 leaf PTEs x a 695-entry `share_ranges`
vector scanned linearly per PTE = ~800M comparisons per fork.

## A/B in one image (only an env var differs)

| K concurrent forks | 1 | 2 | 4 | 8 | 16 | 32 |
|---|---|---|---|---|---|---|
| linear | 146 | 286 | 552 | 1179 | 2322 | 4631 ms |
| bsearch | 79 | 145 | 279 | 550 | 1172 | 2094 ms |

2.21x fork throughput (6.9 -> 15.3 forks/s), per-fork -55% (144.7 -> 65.4 ms). The
linear arm reproduced the independently-briefed baseline (4743 ms, ~150 ms/fork) almost
exactly, so the comparison is valid.

## Mechanism confirmed twice over

vCPU sensitivity, the discriminator the whole diagnosis rested on:

| smp | 2 | 8 | 32 | spread |
|---|---|---|---|---|
| linear | 75 | 89 | 138 ms | +84% |
| bsearch | 62 | 62 | 69 ms | **+11%** |

And the scaling law that matters most for this project - fork cost vs live backend
count at FIXED vCPUs:

| backends | n_threads | range_len | linear | bsearch |
|---|---|---|---|---|
| 8 | 667 | 701 | 150 ms | **73 ms** |
| 64 | 721 | 755 | 161 ms | **75 ms** |
| 256 | 913 | 947 | **191 ms** | **79 ms** |

Linear grows with connection count (+27% from 8 to 256 backends); bsearch is nearly
flat (+8%). So this was never merely an SMP nit: fork got more expensive the more
PostgreSQL backends existed, which is exactly our regime.

## Correctness

The change alters only HOW the "is this VA in the set?" predicate is computed - not
which VAs are selected, no PTE value, no lock, no flush semantics. Sorted, coalesced,
half-open intervals; identical predicate. The memoization is a pure-function cache of
the last matching range, invalidated whenever the range sets change.

## Why it is NOT a standalone upstream PR (scoping conclusion)

I tried to cherry-pick both commits onto `upstream/master` and they conflict. The
reason is decisive: **none of the code they optimize exists on master.** Verified:

    addr_is_shared      on master: 0 occurrences
    addr_is_privatize   on master: 0
    cow_share_ranges    on master: 0
    clone_pt_level0     on master: 0
    clone_address_space on master: 0

All of it is part of the unmerged fork stack. The owner is **#1456**
(`wip/fork-stage2-pr`, "mm: per-child copy-on-write address space for fork()"), which
does have `clone_address_space`.

Cherry-picking onto #1456's branch also conflicts, but only in ONE file
(`core/mmu.cc`, 4 hunks) and only as context drift - all four target functions
(`addr_is_shared`, `addr_is_privatize`, `cow_share_ranges`, `clone_pt_level0`) are
present there. The lineages are 132 commits apart in one direction and 6 in the other,
which explains the drift.

I did not hand-resolve those hunks: this is page-table code and I cannot build-test it
from here, so resolving 4 conflict hunks in `core/mmu.cc` blind would be exactly the
kind of unvalidated change this program has been disciplined about avoiding.

**Correct home:** fold these two commits into #1456 as additional commits, resolved
and build-tested on that branch. That is a small, well-scoped task for an agent with a
box. Until then the work is preserved and signed on `wip/fork-clone-scan`.

## Still open from this task

- The residual ~62-65 ms/fork floor is NOT the scan (now flat vs vCPU count). Needs
  characterising: likely intermediate-table alloc/memset in `clone_pt_level<1>/<2>` or
  the per-PTE write-protect stores. "This is what fork on a 2.3M-PTE address space
  costs" is a useful finding in itself.
- The p99 gate was not re-run to completion. Expected to still FAIL: 65 ms/fork x 32
  concurrent is ~2.1 s, so a fresh-connect probe at VU32 can still exceed 5 s. The
  honest headline is 2.21x fork throughput with the vCPU-scaling term eliminated, NOT
  "gate passed".
- **The safety finding stands separately and is worth more than the perf work:**
  `libc/signal.cc` assigns a new handler thread into a LIVE fork child's address space
  and `core/sched.cc` makes threads inherit their creator's AS, so two CPUs can execute
  with the same CR3. That makes any local-only TLB flush unsound, and puts the existing
  `exception_depth >= 2` local-flush path on an invariant that can be violated. Latent
  memory-corruption risk, deserves its own upstream issue or at minimum a corrected
  comment.
