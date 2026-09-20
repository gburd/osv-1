# Why OSv/PG once measured FASTER than Linux/PG, and now measures 4.9-13.8x slower

Answer: **OSv did not regress. The comparison target was wrong, and correcting it reversed the sign.**

## The arithmetic of the reversal
Every historical "OSv beats Linux" claim was a ratio against a number labelled "the Linux VU8 baseline":

    OSv Firecracker VU8 = 113,323 NOPM
      vs Linux 38,948  (earliest baseline)   = 2.91x  OSv AHEAD   <- the "2.9x faster" claim
      vs Linux 99,504  (16-vCPU VM, glibc)   = 1.14x  OSv ahead
      vs Linux 213,505 (32-CPU metal, musl)  = 0.53x  OSv BEHIND

The OSv number never moved. **The denominator did.**

## What was wrong with the old baseline: three confounds, all favouring OSv
The old reference was a **16-vCPU VM running glibc**, compared against **OSv guests on 32-vCPU bare
metal running musl**. Correcting geometry and libc:

    2x the CPU count      predicts ~199k   (1.99x)
    metal instead of a VM  a further        1.17x
    => ~232k predicted;  232,139 measured.  The shape matches the explanation exactly.

So the correction is not an outlier or a mis-measurement - it is what the hardware predicts. And the
one remaining asymmetry **disfavours Linux**: Linux ran with a 16 GiB ARC cap proven binding under load
while the OSv guest had ~32 GiB. **Linux was given half the cache and was still faster.**

## And OSv genuinely did not change
    old unfixed x86 base, VU8   43,407 NOPM
    new fully-fixed base, VU8   43,510 NOPM     = +0.24%

Four real defects fixed (psABI TCB canary, O(PTEs x threads) fork scan, 2 MB large-page split, ELF
object-cache AS bug) moved throughput by **0.24%**. They were correctness and latency fixes, not
throughput fixes. Connect latency went 117 ms -> 4 ms; NOPM did not budge.

## What to do about it: the gap has TWO components, and they need different fixes

Converting NOPM to per-transaction latency (NOPM/TPM = 0.434 measured):

    OSv   VU8  43,510 NOPM -> 1,671 tx/s -> 4.79 ms/tx
    Linux VU8 213,505 NOPM -> 8,199 tx/s -> 0.98 ms/tx
    OSv pays 3.81 ms MORE per transaction, at only 8-way concurrency.

**A global lock cannot cost 3.8 ms/tx with 8 clients in flight.** So:

- **Component 1, the LEVEL (4.9x at VU8): a fixed per-COMMIT cost.** Concurrency-independent, paid by
  every transaction. This is the bigger share and the better target.
- **Component 2, the WIDENING (4.9x -> 9.9x -> 13.8x): contention/scaling.** This is where
  `dentry_hash_lock` and PR #1503 plausibly live.

I had queued #1503 as the next experiment. **The latency arithmetic says that is the second priority,
not the first.**

## Component 1 is ALREADY ROOT-CAUSED, AND A FIX ALREADY EXISTS UNSHIPPED

Measured 2026-08-24: native OSv-ZFS RW c16, `synchronous_commit=ON` 878 tps @ 18.0 ms vs `OFF` 5528 tps
@ 2.9 ms - **6.3x**, and OFF put OSv at 0.73x of Linux, i.e. competitive. **The per-commit synchronous
ZIL flush was the entire gap. OSv's ZFS is not a slow engine.**

The mechanism, now confirmed in source rather than inferred:

`modules/open_zfs/patches/0001-...-SPL-for-OpenZFS.patch` implements the SPL's `cv_timedwait_hires` as

    ticks = (clock_t)(tim / (1000000000LL / hz));   /* hz = 1000 -> 1 ms per tick */
    return cv_timedwait(cvp, mp, ticks);

`zil.c:3334` calls it as the batch window, sized at `zfs_commit_timeout_pct` = **10% of the last LWB
write latency**, i.e. tens to hundreds of microseconds. Two distinct bugs:

1. **Truncation.** At hz=1000 every window below 1 ms integer-divides to **0 ticks**. Windows of
   10/25/50/100/250/500/999 us all become zero: the waiter never waits, never accumulates a second itx,
   so it is **one lwb write + one NVMe FLUSH per commit.** Batching is defeated outright.
2. **Worse: an absolute deadline fed to a relative wait.** The call passes `CALLOUT_FLAG_ABSOLUTE`, so
   the wrapper correctly skips adding `gethrtime()` - then divides the **absolute** ns timestamp by
   1e6 and hands the result to `cv_timedwait`, which treats it as **relative**. A current uptime of
   ~627,161,878,386,903 ns becomes ~627,161,878 ticks = **~7.3 days**. The timeout never fires, so
   upstream's "responsibility (2)" - issue the lwb when the window expires - never runs at all.

**The fix already exists: commit `6d93cb7c5`**, "zfs: nanosecond-precise cv_timedwait_hires so ZIL
commits coalesce on OSv" - adds `openzfs_cv_timedwait_hires()` waiting true nanoseconds and handling
the absolute/relative flag correctly. 98 lines across `netport1.cc`, `kcondvar.h`, and a new patch 0030.

    on gh-fork/wip/pg-zfs-bench ONLY   |   NOT upstream   |   never filed as a PR
    NOT an ancestor of cbbf74e7 => TODAY'S 43,510 WAS MEASURED WITHOUT IT

## Revised next steps
1. **File `6d93cb7c5` as a PR** and get it onto the benchmark base. Generic OSv/SPL correctness fix
   (a time-unit bug), exactly the G2 shape - nothing PostgreSQL-specific.
2. **Re-measure VU8 with and without it, same binary if possible.** Prediction from the August data: the
   *level* improves substantially; the declining *shape* likely does not, because that is component 2.
3. **Then** sweep #1503's `OSV_VFS_DENTRY_PERBUCKET` on/off for the widening.
4. Do not repeat: today's sweep is sound and quiesced; only the base needs to change.

## FILED: PR #1505, and the stranded fix was itself broken

Filed **#1505** "zfs: honour sub-tick timeouts in the SPL cv_timedwait_hires" (base=master, clean by
`git merge-tree` from a worktree at upstream/master, G-signed `6ccffce82`, branch
`gh-fork/pr/zfs-spl-hires-timeout`).

**I nearly shipped the stranded fix `6d93cb7c5` verbatim. It was broken.** Three separate errors caught
only by checking rather than trusting:

1. **It patched the wrong artifact.** `6d93cb7c5` adds a `patches/0030-*.patch` targeting
   `include/os/osv/spl/sys/condvar.h`. On master the OSv SPL layer is **parent-tracked source** at
   `modules/open_zfs/osv/`, not patch-applied; the patch directory holds only 2 patches for genuine
   upstream-file edits. Cherry-picking it left the real header **untouched** - a no-op fix that looks
   applied. (Verified: the real `cv_timedwait_hires` body was still the tick-converting one afterwards.)
2. **It would have broken the build for everyone else.** `Makefile:62-64` applies
   `patches/*.patch` inside the submodule with `git apply ... 2>/dev/null`. A patch whose target does not
   exist there fails; the error is swallowed and only a stamp file records success.
3. **The clock base was wrong.** `6d93cb7c5` subtracts `osv::clock::uptime::now()`. But `gethrtime()` on
   OSv resolves to **`CLOCK_REALTIME`** - `compat/opensolaris/sys/time.h` `#define CLOCK_UPTIME
   CLOCK_REALTIME` - and `zil.c` builds its absolute deadline *from `gethrtime()`*. Subtracting a
   monotonic reading from a wall deadline yields ~**56 years** of positive delta, so it would wait
   effectively forever: **broken in the same direction as the bug it was meant to fix.**

The filed version derives `now` from `gethrtime()` itself, so no clock mismatch is possible, and edits
the parent-tracked header directly. Both paths verified by compiling the fixed body standalone:
ABSOLUTE 250us -> 250,000 ns requested; RELATIVE 250us -> 250,000 ns; past deadline -> -1. The old body
under the same harness: **ticks=1,789,146,780,736 = 20,707 days**, or zero if it had stayed relative.

**Also re-derived, and I had already written it down:** `git apply a.patch b.patch` is **NOT atomic** -
`.local/GIT-APPLY-NOT-ATOMIC.md` records the same conclusion from 2026-09-07. Re-proved it with a
2-file control. And I read `$?` after a pipe once during that test, got `rc=0` for a failing command,
and had to redo it - the exact trap in my own notes.

## Standing correction to the campaign's priorities
The next benchmark must test **#1505 first**, not #1503. Component 1 (the 3.81 ms/tx fixed cost) is the
larger share of the gap and now has a candidate fix; component 2 (the widening) is #1503's territory.
Prediction to falsify: **#1505 lifts the LEVEL at VU8 and does NOT fix the declining SHAPE.**
