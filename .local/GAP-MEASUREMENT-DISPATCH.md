# Dispatched: write the dentry fix, then measure how much of the 21x it recovers

2026-09-09, agent 1b02c3e6, `Owner=agent-gapmeasure`.

## Why this needed a fix written first
I checked before dispatching: **the dentry-lock fix does not exist on any branch.** Every base still
declares one `static mutex dentry_hash_lock`. So "measure with both fixes" was not yet possible - the
fork fix is real and landed, the dentry fix was only root-caused. The brief therefore writes it first.

Also verified the fork fix should carry to x86: its `core/mmu.cc` change has **zero** arch-specific
guards, and it ships **two env A/B switches** (`OSV_FORK_RANGE_BS`, `OSV_FORK_LARGE_SHARE`), so
attribution can be same-binary.

## The target to beat

    VU   Linux median   OSv x86 (pre-fix)   ratio
     8      213,505          43,407          4.9x
    32      510,367          34,789         14.7x
    64      614,277 PEAK     28,377         21.6x
    96      547,813          26,047         21.0x

Linux scales to VU64; OSv peaks at VU8. **The shape difference is the thing the two fixes should
address**, since both causes are concurrency-scaling defects rather than per-operation costs.

## Task 1: two separable defects, both to be fixed and measured separately
(a) **the deadlock** - `dentry_hash_lock` held across an allocation that sleeps
    (`l1::alloc_page` -> `l1::refill` -> blocks; its own comment at `mempool.cc:1624` says so).
    The exact malloc site was NOT recoverable from the truncated unwind, so it must be found by
    inspection. **If no allocation under the lock exists, my mechanism is wrong and I want to hear
    that** rather than have a fix built on a wrong story.
(b) **the scalability defect** - one global mutex for `DENTRY_BUCKETS 32`, which already exist, taken
    at 14 sites. Per-bucket locking is obvious, but `drele` does `LIST_REMOVE` + `vn_del_name` under
    the lock and `dentry_alloc` inserts, so multi-bucket sites must be checked rather than assumed
    independent.

## Attribution design
Three same-binary arms where possible: **baseline / fork-only / fork+dentry**, interleaved rather than
run in blocks, because ARC warmth and ZFS free-space fragmentation drift monotonically and would
otherwise be credited to the switch. Order to be reported.

## Specifically wanted: the x86 connect number
The **3.98 ms** connect median is aarch64-only so far. Whether the fork fix carries across ISAs is
open, and it is a cheap, high-value datum.

## Known trap carried forward
`max_wal_size=64GB` is **throughput-dependent**: 6 timed / 0 requested at ~43k NOPM, but **1 timed /
18 requested at 614k**. If OSv gets fast enough to reach that regime, the checkpoint pathology returns
and must be reported rather than treated as noise.

## Every substrate footgun from the campaign is in the brief
Including the two one-second pre-boot greps (`remap_segments_in_current_address_space` must be 3;
`.PHONY: module build` or the shadowed-build trap ships a PostgreSQL-free image reporting success),
verifying postgres presence **by image size**, `conf_zfs=openzfs` or bsd_zfs is silently selected, no
`zfs-2.4.1-osv` banner exists, `-M pc` not q35, `loader.img` on aarch64, pool created once then
import-only, GUCs on the command line and verified externally, `vucomplete` not `runtimer`, and
rotating the xtprof log per run.

## Capacity constraint tightened, sequencing imposed

Measured after dispatch: **696 vCPU against a 512 quota**, worse than the 656 in the brief. Other
projects hold the bulk:

    192  c8g.metal-48xl    libumem-arm-hi
    192  c7i.metal-48xl    libumem-intel-hi
     96  c7i.24xlarge      libdb-perf-harness
     64  i4i.16xlarge      (Project=noxu-bench)

So two concurrent metal boxes are off the table. Instructed:
- **Sequence x86 first, tear down, then aarch64.** x86 is where the Linux baseline was measured AND
  where the fork fix is unproven (the 3.98 ms connect result is aarch64-only), so it carries more
  information. aarch64 not being reached is an acceptable outcome if stated.
- **Do the dentry fix development on a CHEAP box, not metal.** Writing and correctness-testing a VFS
  lock change needs no `/dev/kvm`: a `c5.4xlarge` under TCG suffices for building, the `tst-*` suite,
  and confirming the deadlock reproducer no longer wedges. Only the *measurement* needs metal. That
  keeps a 96-vCPU box out of a strained pool during hours of iteration.
- **Consequence flagged**: if development happens on one box and measurement on another, the identity
  tuple must record the **same osv SHA** for both - build once, or rebuild from the identical commit
  and say so, so a dev build and a metal build cannot diverge silently.

## Priority order if the clock runs short
1. **The dentry fix with correctness evidence.** It is upstreamable on its own merit - a single global
   mutex for 32 already-existing buckets is a defect whether or not it explains the gap - and
   `fs/vfs/vfs_dentry.cc` **exists on `upstream/master`**, so this may be the **first master-eligible
   fix of the entire campaign** rather than another #1456 comment.
2. **The x86 connect probe** - cheap, and it answers whether the fork win crosses ISAs.
3. The x86 NOPM sweep: baseline vs fork-only vs fork+dentry, interleaved.
4. aarch64 if it fits.
