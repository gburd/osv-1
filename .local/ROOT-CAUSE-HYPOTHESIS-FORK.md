# Root-cause hypothesis for the performance gap: the fork fix was never in the benchmarks

2026-09-08. Found while scoping the next campaign, and it is embarrassing in a useful way.

## The arithmetic that points at fork

    Linux connect median          4.0-4.3 ms
    OSv aarch64 connect median    99.9-106.8 ms    (~25x worse)
    measured fork cost (earlier)  65-150 ms/fork   <- SAME ORDER OF MAGNITUDE

PostgreSQL forks one backend per connection, so **connect latency IS fork latency**. And at VU32,
32 concurrent connects x ~100 ms of serialized fork work produces exactly the observed failure:
fork starvation, `autovacuum worker took too long to start` 99 times, backend pids reaching ~127k.

**So items 2 (aarch64 >VU32), 3 (connect latency) and 4 (fork starvation) are plausibly ONE root
cause**, not three. That reframes the work.

## And the fix already exists, unmerged

`gh-fork/wip/fork-clone-scan` has:

    9b4ea6578  mm: fix O(PTEs x threads) range scan in fork page-table clone
    65279b938  mm: memoize the fork clone range lookup (per-PTE cost 65 -> 40 cycles)

Measured when written: **2.21x fork throughput** (6.9 -> 15.3 forks/s), per-fork **144.7 -> 65.4
ms**, vCPU sensitivity collapsing from +84% to +11%, and cost scaling with CONNECTION count
(linear 150->191 ms at 8->256 backends; fixed 73->79 ms flat).

**Neither benchmarked tree contains it.** Verified by inspecting `core/mmu.cc` on both:

    wip/aarch64-boot-plus-elf-as-fix   -> still the linear scan
    wip/pg-v26-faultfix-repinned       -> still the linear scan

    static bool addr_is_shared(uintptr_t va) {
        if (!cow_share_ranges) return false;
        for (auto &r : *cow_share_ranges) { ... }   // O(ranges) per PTE
    }

So both arms measured a tree carrying a known, already-fixed O(PTEs x threads) fork cost. The
2.21x figure was measured on a different branch and never propagated into the benchmark lineage -
the same failure mode as the dangling submodule pin: **work that exists but is not where it is
needed.**

## It merges cleanly
`git merge-tree --write-tree --messages wip/aarch64-boot-plus-elf-as-fix wip/fork-clone-scan`
exits 0 with **zero conflicts**. So this is a cheap experiment, not a port.

## Prediction to test (stated in advance so it can be wrong)
Folding the scan fix into the benchmark base should:
- cut connect-probe median materially from ~100 ms (toward the ~40-65 ms/fork residual floor);
- raise the aarch64 VU32 ceiling, because starvation is fork-throughput-bound;
- improve NOPM most at HIGH VU, where fork churn is greatest, and little at VU8.
If connect latency does NOT move, the hypothesis is wrong and fork is not the gap - which is
equally worth knowing. **The residual floor matters too**: even at 65 ms/fork, Linux's 4 ms
median is 16x better, so the scan fix is necessary but probably not sufficient.

## The experiment got better: the patch ships its own A/B switch

Agent d55c4a8f found, and I verified at `core/mmu.cc:388-414` on `wip/fork-clone-scan`:

    OSV_FORK_TIMING=1     per-fork phase breakdown via rdtsc
    OSV_FORK_RANGE_BS=0   disable the sorted-range binary search, fall back to the linear scan
                          (default is TRUE, i.e. the fast path)

So **one image does both the A/B and the phase breakdown, with no rebuild.**

**Why that is materially better than what I briefed:** it eliminates build variance as a confound.
Same binary, same boot, same dataset, same ARC state - only an env var differs. Every previous fork
measurement in this project compared two *builds*, leaving room for "maybe something else changed".
This does not.

### Three methodological points I added
1. **Interleave the A/B.** All-B-then-all-A would let ARC warmth, ZFS free-space fragmentation and
   autovacuum state drift monotonically across the run and be attributed to the switch. Alternate
   or randomise, and report the order. That was the one hole in an otherwise clean design.
2. **Report the phase breakdown for BOTH settings**, since which phase the fix removes and which
   remain IS the residual characterisation, obtained free from the same runs. And quantify whether
   `OSV_FORK_TIMING` itself perturbs the measurement (rdtsc per phase per fork is not free) by
   running one cell with it on and off.
3. **Prove the switch bound.** `env_flag_on(..., true)` defaults to the FAST path, so a typo in the
   env var silently yields fixed behaviour in *both* arms - you would measure "no difference" and
   wrongly conclude the fix does nothing. Have the guest print the resolved value, or confirm the
   phase breakdown shows a scan cost that actually changes. This project has been bitten repeatedly
   by silent no-ops that still stamp success: a no-op `fsync`, a ramfs PGDATA, bsd_zfs masquerading
   as OpenZFS, and a PostgreSQL-free image that built cleanly.

### Coordination
Asked it to push the merged base to `gh-fork` and name it **as soon as it builds and boots**, not
at the end, so `agent-fcmetal` can use it for the Firecracker arm instead of measuring a known-slow
fork path.

## SCOPE CORRECTION: it is EIGHT commits, not two, and my clean-merge check never proved otherwise

Agent d55c4a8f caught this. Verified:

    git log wip/aarch64-boot-plus-elf-as-fix..wip/fork-clone-scan
      65279b938  mm: memoize the fork clone range lookup            <- briefed
      9b4ea6578  mm: fix O(PTEs x threads) range scan               <- briefed
      73a332f26  mm: shared-anon fork write faults skip the AS-wide write lock
      2ece6af03  mm: lock-free RCU shared-anon fork page registry
      9b3207e5c  virtio-blk: do not hold the per-queue lock while draining completions
      859210d54  mm: report largest free range on OOM
      57e29d80e  mm: log largest free range and total free on OOM
      866bc8b6a  mm: retry reclaim across shrink passes before declaring OOM

    diffstat: core/mempool.cc +62, core/mmu.cc +407, drivers/virtio-blk.cc +24,
              include/osv/mempool.hh +5, modules/open_zfs/patches/0031-*.patch +/-2

**My reasoning error, stated plainly: `git merge-tree` reporting zero conflicts proved the branch
MERGES. I presented it as evidence that only the two scan commits land. Those are different claims.**
The correct scope check is `git log base..branch` plus a diffstat, which is what the agent ran.

**Standing lesson: mergeability is not scope.**

### Consequence for attribution
Any NOPM/HammerDB delta against the *previously benchmarked* tree is attributable to **eight**
commits, so it cannot credit the scan fix. **The same-binary `OSV_FORK_RANGE_BS` A/B is the ONLY
clean attribution**, because the other six commits are identical in both arms. Report structure
agreed: the env-var A/B attributes the scan fix; cross-base comparisons are labelled "this base vs
that base, 8 commits" and used for context only.

### An unexpected payoff
`866bc8b6a` (retry reclaim across shrink passes) and `859210d54` (report largest free range on OOM)
land directly on the open x86 bug: the **"37.41 GiB free but largest contiguous range 1.00 MiB"**
abort. So on this base that abort may already be fixed, or at least far better instrumented. Asked
both agents to capture the new diagnostic if they hit it, and to **say so if they do NOT hit it
where the x86 arm did** - "fixed by a commit already written and unmerged" would be the **second
instance today** of work existing but not being where it was needed (the first being the scan fix
itself).

### Shared base published early, deliberately
`gh-fork wip/forkroot-arm-base` (`12eac3a04`) was pushed BEFORE validation so `agent-fcmetal` would
not be blocked. I relayed it with two warnings: (1) do not commit a build to it until build+boot is
confirmed, since an unbootable shared base is worse than none; (2) **it is aarch64-rooted**, so for
an x86 Firecracker arm the cleaner move is `wip/pg-v26-faultfix-repinned` + a merge of
`wip/fork-clone-scan`, and either way it must say which base it used.

### Silent-no-op hole closed
The agent added a boot-time `FORKFLAG` print of the resolved env-var value. That closes the hole I
flagged where a typo would silently give the fast path in BOTH arms and produce a fake null result.

## CORRECTION TO THE CORRECTION: "eight commits" is true of the aarch64 base ONLY

Agent 7d0737f3 caught that I broadcast the eight-commit scope warning as a property of the branch.
It is a property of the **pair**. Measured against the x86 base:

    git rev-list --count wip/pg-v26-faultfix-repinned..wip/fork-clone-scan  = 2
    diffstat: core/mmu.cc +211, plus 2 lines in the ARC patch file. 2 files.

    73a332f26 2ece6af03 9b3207e5c 859210d54 57e29d80e 866bc8b6a
      -> ALL SIX are already ancestors of wip/pg-v26-faultfix-repinned

So relative to the x86 base the fork-scan merge really is a **2-commit, mmu-only, +211-line** delta.
My warning was correct for `wip/aarch64-boot-plus-elf-as-fix` and wrong for the x86 base.

**Standing lesson, now stated properly: scope is a property of the PAIR (base, branch), never of the
branch alone, and must be re-measured per base.** This is the same error I made earlier today in a
different costume - first claiming a clean merge proved scope, now claiming a scope measured against
one base held against another. Both times an agent had to measure what I had asserted.

### Two consequences that improve the campaign
1. **The improved OOM diagnostic is already live on the x86 base.** `866bc8b6a` (retry reclaim across
   shrink passes) and `859210d54` (report largest free range on OOM) are ancestors of `repinned`, so
   Task B gets the new output if the "37.41 GiB free / 1.00 MiB largest range" abort fires - and **a
   non-recurrence where the previous x86 run saw it is already an apples-to-apples statement on this
   base**, not a confounded one. That would be the second case today of a bug fixed by a commit that
   was already written and merely unmerged.
2. **Firecracker numbers become cleanly comparable.** With only the 2 scan commits differing from the
   previously-benchmarked x86 tree, a Firecracker figure on this base can legitimately be compared
   against the earlier x86 QEMU-KVM peak (43,407 NOPM @ VU8) for the hypervisor question, with any
   fork-related delta attributable to those 2 commits specifically.

### Base decision (agent's, better reasoned than mine)
Rejected `wip/forkroot-arm-base` for the x86 arm: 20 commits ahead of repinned, aarch64-port lineage
(split-TTBR page tables, GICv3 SGI, phys-map, RNDR), and unvalidated - the wrong risk profile for an
x86 measurement. Taking `wip/pg-v26-faultfix-repinned` + a local merge of `wip/fork-clone-scan`, with
plain `124caf42a` as the fallback.

### Cross-cut now available
`agent-forkroot` is running the same 2 commits as a same-binary `OSV_FORK_RANGE_BS` A/B on aarch64,
while this agent runs them on x86 under two hypervisors. Between them there will be both a
**cross-hypervisor** and a **cross-ISA** read on the identical change.
