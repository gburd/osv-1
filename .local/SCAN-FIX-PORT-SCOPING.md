# Scan fix: cherry-pick refuted, minimal port authorised

2026-09-07. Agent 342ad151 stopped Task A before spending a box and refuted my
"context drift" premise. Verified independently; the agent was right on every point.

## What I got wrong

I inspected the cherry-pick of `9b4ea6578` onto `wip/fork-stage2-pr`, saw ONE
conflicted file (`core/mmu.cc`, 4 hunks), confirmed the four target functions existed
on that branch, and concluded "context drift, not semantic". That was too shallow a
check: I verified the TARGETS existed but not the DEPENDENCIES.

## What is actually true

    fork_arena                on stage2: 0 files   | on clone-scan: 43 files
    fork_shared_module_ranges on stage2: 0 files   | on clone-scan: 1 file
    clone_address_space       stage2: 128 lines    | clone-scan: 253 lines

- `fork_arena` / `fork_arena::kernel_heap_scope`: absent from stage2 entirely (present
  in 60+ other gh-fork branches).
- `fork_shared_module_ranges`: absent from stage2, yet the fix's
  `share_ranges.reserve(... + fork_shared_module_ranges.size())` references it.
- `modules/open_zfs/patches/0031-*` is deleted on stage2 (modify/delete), so that part
  of the commit is dropped anyway.
- Hunk 4 is a genuine structural divergence: on clone-scan, `clone_address_space` was
  restructured so the child address_space and a `vma_snap` vector are pre-reserved
  BEFORE the lock and the child's vma_list is rebuilt AFTER `vmas_mutex` is released
  (the documented malloc-during-fork deadlock cure). On stage2 everything still happens
  inside `WITH_LOCK(...for_write)` with `return child;` from inside the lock. 199
  differing lines.

Resolving hunk 4 would mean either porting that whole refactor into #1456 - a much
larger behavioural change than the briefed perf fix - or hand-writing a third variant
of the function that has never been built or measured. Neither is acceptable.

## The authorised path: a fresh minimal commit

The perf PRIMITIVE is portable in isolation, which I verified: on stage2
`addr_is_shared`/`addr_is_privatize` exist with identical bodies, `cow_share_ranges`
appears 6 times in `core/mmu.cc`, and the `with_all_threads` amplifier is present. So
the mechanism and its amplifier are both there; only the surrounding machinery differs.

Authorised: a fresh commit on `wip/fork-stage2-pr` implementing ONLY the sorted +
coalesced half-open interval lookup with the last-match memo. Explicitly excluded:
`fork_arena`, any `fork_shared_module_ranges` reference, `OSV_FORK_TIMING`
instrumentation, `modules/open_zfs/patches/*`, and any restructuring of
`clone_address_space`.

Conditions: must BUILD (page-table code - no unbuilt resolutions), must boot and serve
PostgreSQL plus survive a fork-heavy operation (schema build at pg_num_vu 16 suffices),
and must state honestly that the quoted measurements (2.21x; 144.7 -> 65.4 ms/fork;
vCPU spread +84% -> +11%; backend scaling 150/161/191 vs 73/75/79 ms) were taken on the
fuller fork stack and that this commit ports only the lookup change. No implying the
numbers were reproduced on stage2 unless they actually are.

`wip/fork-clone-scan` stays as-is: it is the record of the full measured work for
whenever the rest of the fork stack lands.

## Lesson

When checking whether a cherry-pick is "just drift", verifying that the TARGET symbols
exist is not sufficient - check the commit's DEPENDENCIES too, and compare function
sizes to catch restructuring. `git grep -l <symbol> <branch>` across the whole tree
(not just the conflicted file) would have caught this in seconds.

Fourth premise of mine corrected this session, and the second time an agent stopping
instead of guessing was the right move. Both times it saved a wasted bare-metal box and
prevented an unvalidated change to memory-management code.

## Pre-build verification (agent 342ad151, before spending the box)

Two checks done on the HOST before launching, both of which I verified:

**1. Predicate equivalence proven without a guest.** The new predicate was extracted
verbatim into a standalone harness (`/tmp/maint7-pred-check.cc`, g++ -O2) and run over
1,560,000 VA lookups across 3000 random range sets, including empty, zero-length,
duplicate, adjacent and overlapping ranges, in BOTH ascending order (the clone walk's
real access pattern, which the memo is tuned for) and random order (to rule out
order-dependence in the memo). Result: identical to the original linear scan at every
VA, and the coalesced view is strictly ordered and disjoint.

This is stronger evidence than a guest boot for the predicate itself, because a boot
only exercises whatever ranges that particular run happens to produce. Asked for the
harness to be included with the commit - it is reproducible without a guest, which is
what a reviewer will want.

**2. No new invalidation hook needed - verified by me too.** On
`wip/fork-stage2-pr`, inside the single `WITH_LOCK(vmas_mutex->for_write())`:

    build the vectors (with_all_threads push_back loop completes)
    cow_share_ranges     = &share_ranges;      // line 450
    cow_privatize_ranges = &privatize_ranges;  // line 451
    ... clone_pt_level<2>(...) walk ...
    cow_share_ranges     = nullptr;            // line 476
    cow_privatize_ranges = nullptr;            // line 477

Nothing mutates the vectors between publish and clear, so `build_sorted_ranges()` at
publish time is the only invalidation point required. The agent explicitly did NOT
invent a hook, which was the specific failure mode I had flagged.

Remaining caution passed on: sort a copy or sort before publishing, and confirm nothing
reads `share_ranges`/`privatize_ranges` expecting insertion order.
