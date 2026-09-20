# The shape question: diagnosed. The VU32 wedge is the dentry AB-BA deadlock (#1502). Fix built.

## The two phenomena
- **VU8->VU16 DECLINE** (104640 -> 64839, WAKE_PULL on): guest still progressing, WAL/NULL-bound.
- **VU32 WEDGE**: all threads asleep, 0 runnable, empty wakeup mask, 26.9 GiB free, guest network
  also dead. A TRUE DEADLOCK (nobody ever runnable), not a lost wake or memory stall.

## Root cause of the wedge (from a prior LIVE-guest backtrace, .local/WEDGE-BACKTRACE-CAPTURED.md)
AB-BA lock inversion between the global dentry_hash_lock and the vnode lock:
    namei  (vfs_lookup.cc:178/284): vn_lock -> dentry_hash_lock
    drele  (vfs_dentry.cc:221 -> vn_del_name -> vfs_vnode.cc:531): dentry_hash_lock -> vn_lock
Reachable on the same vnode when releasing a directory dentry; namei itself does drele(ddp) on
directory dentries, so it is not theoretical. The empty wakeup mask is the signature only a true
deadlock produces - a lost wake or slow path would eventually make progress with 27 GiB free.

## Why the a2a base wedges: it has NEITHER #1502 NOR #1503
bench/a2a-all-levers (from cbbf74e7) still has the raw global dentry_hash_lock at 14 sites, no
lock-order fix. So the VU32 wedge is EXPECTED - the run is exercising unfixed code.

## Why this is DIFFERENT from the dentry per-chain A/B (which was a throughput null)
- #1503 (per-chain locking) reduces CONTENTION; the earlier A/B showed it does NOT move throughput
  because the ceiling was the fsync scan (#1507) + WAL serialization, not lock contention.
- #1502 (lock ORDER) makes the DEADLOCK impossible. A per-bucket lock still inverts against vn_lock,
  so per-chain does NOT fix the wedge - only the ordering fix does.
- So the SHAPE fix is #1502, and it was never measured for scaling (it has the deadlock-assertion
  proof but no throughput/scaling number). This run supplies that.

## The fix, built and ready: bench/a2a-shape-fix (d9e9dfc70)
= bench/a2a-all-levers + #1502's 3 commits (AB-BA fix, dentry_move alloc-hoist, stress test), NOT
per-chain. dentry_move conflict resolved by combining both invariants (outside-lock AND fork-arena
kernel heap). Lock-order ASSERTION present (fires on unfixed vn_lock path). Braces balanced, leak-clean.

## The experiment (after the current a2a run finishes)
Re-run VU8/16/32/64 on bench/a2a-shape-fix, matched to the same Linux arm:
- If VU32 no longer wedges AND VU16 stops declining -> #1502 fixes BOTH (decline was early lock-order
  contention). Best case: OSv scales.
- If VU32 no longer wedges but VU16 still declines -> #1502 lifts the hard ceiling (sweep can go
  higher), and the residual decline is separately WAL-commit serialization (the next target).
Either way #1502 becomes an end-to-end-qualified PR (removes the wedge, enables the sweep) instead of
just assertion-proven.

## The remaining decline candidate (if it survives #1502): WAL-commit serialization
VU8 was WALWrite-bound (31-34%), only 7.7/32 vCPU busy - backends blocked on WAL fsync completion, not
runnable-and-unplaced (hence WAKE_PULL correctly a no-op). If the decline persists past #1502, the next
investigation is how OSv services concurrent WAL commits: the single ZIL commit path, or the single
virtio-blk completion thread serializing all queues' completions. That is the follow-on G2 target.
