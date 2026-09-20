# DRAFT reply - PR #1502, @nyh review (pending review id 5260826718)

STATUS: **DO NOT POST YET.** The review is PENDING/unsubmitted as of 2026-09-20 15:00Z. The three
comments are visible only through the events API; they 404 on `pulls/comments/<id>` and are absent from
`pulls/1502/comments` and GraphQL `reviewThreads`. Replying into an unsubmitted review risks cross-posting
and pre-empting comments he is still writing. Post when the review is submitted, as three in-thread
replies (one per comment id) plus, optionally, the short top-level summary at the bottom.

Comment ids to reply to, in order:
- 4057182904 - fs/vfs/vfs_dentry.cc, duplicate extern decl (14:32:19Z)
- 4057202371 - fs/vfs/vfs_dentry.cc, the __thread depth counter (14:42:17Z)
- 4057206258 - fs/vfs/vfs_dentry.cc, WITH_LOCK hook (14:44:03Z)

All three are correct. Comment 2 is the substantive one and it makes the patch smaller. Nothing here is a
disagreement, so the reply is short and the rework is one commit.

---

## Reply to 4057182904 (duplicate extern declaration)

> Nitpick: if it's already declared in vfs.h, and this file includes that header file, why do we need to
> declare it again here? I think it's harmless, but also useless.

Correct, it is useless - removed. `fs/vfs/vfs.h` already declares it inside the `__BEGIN_DECLS` block
(guarded by the same `#ifdef DEBUG_VFS`), and this file includes `"vfs.h"`, so the local
`extern "C" bool vfs_dentry_hash_lock_held(void);` was redundant. It was a leftover from an earlier
revision where the definition lived in a different translation unit than the declaration.

---

## Reply to 4057202371 (the __thread depth counter) - THE SUBSTANTIVE ONE

> nitpick: why is these extra depth variables needed? Don't our locks already have a depth that we can use?

They are not needed, and you are pointing at exactly the right thing. `dentry_hash_lock` is a `mutex`
(`fs/vfs/vfs_dentry.cc`), and `mutex` already answers the precise question the counter was reimplementing:

- `include/lockfree/mutex.hh:89` - `bool owned() const;`
- `core/lfmutex.cc:308-311` - `bool mutex::owned() const { return owner.load(std::memory_order_relaxed) == sched::thread::current(); }`
- `include/osv/mutex.h:43-46` - `static inline bool mutex_owned(mutex_t* m) { return m->owned(); }`

`owned()` is "held by the *current* thread", which is the same predicate as
`dentry_hash_lock_depth != 0`. So the whole apparatus goes away and the helper becomes a one-liner:

```c
bool vfs_dentry_hash_lock_held(void)
{
    return dentry_hash_lock.owned();
}
```

That deletes the `__thread` variable, `dentry_hash_lock_enter()`/`dentry_hash_lock_exit()`, their
non-DEBUG_VFS no-op stubs, and every paired call site.

It is also strictly more robust, not just shorter: a hand-maintained counter can drift out of sync with
the real lock state if any future call site takes the lock without the paired `enter()`/`exit()`, and that
drift would silently weaken or falsely fire the `vn_lock()` assertion. `owned()` is read from the lock
itself, so it cannot disagree with reality. Thanks - this removes a latent bug class, not just lines.

(Note on `getdepth()`: I only need the boolean, so `owned()` is the right one. The assertion is
"does this thread hold it at all", and recursion depth never mattered.)

---

## Reply to 4057206258 (hooking WITH_LOCK)

> Nitpick: can't we fix WITH_LOCK(dentry_hash_lock) to do those dentry_hash_lock_enter()/exit() if they
> are really needed?

Agreed on the critique, and your previous comment gives a better answer than modifying `WITH_LOCK`:
once the predicate is `dentry_hash_lock.owned()`, there is nothing left to hook. No enter/exit exists, so
`WITH_LOCK` needs no change and the one remaining `WITH_LOCK(dentry_hash_lock)` site in `dentry_move()`
just works. I would rather not touch `WITH_LOCK` for a DEBUG_VFS-only check anyway, since it is used
everywhere in the tree.

---

## Optional short top-level comment (post only if a summary helps; the in-thread replies stand alone)

Thanks for the review. All three are right and the net effect is a smaller patch:

1. dropped the duplicate `extern` declaration (`vfs.h` already has it);
2. deleted the `__thread` depth counter, the `enter()`/`exit()` helpers, their no-op stubs and all paired
   call sites - `vfs_dentry_hash_lock_held()` is now `return dentry_hash_lock.owned();`, using the
   existing `lockfree::mutex::owned()` (`core/lfmutex.cc:308`), which is the same "held by the current
   thread" predicate and cannot drift out of sync with the lock the way a hand-kept counter can;
3. `WITH_LOCK` unchanged - with `owned()` there is no hook to add.

The lock-order rule, the `vn_lock()` assertion and the actual AB-BA fix in `drele()` are unchanged; only
the way the assertion asks its question changed. Re-validated with <BUILD/TEST EVIDENCE - fill in>.

---

## Rework plan (do this before posting, so the reply is true when it lands)

Per `.local/PR1502-REVIEW-ANALYSIS.md`. On `pr/vfs-dentry-lock-order` (currently `ccfedefd4`):

1. delete the local `extern "C"` decl (comment 1);
2. delete `__thread dentry_hash_lock_depth`, `dentry_hash_lock_enter/exit`, and the `#else` no-op stubs;
3. `vfs_dentry_hash_lock_held()` -> `return dentry_hash_lock.owned();`
4. remove the paired `enter()`/`exit()` at all call sites, including the two inside the
   `WITH_LOCK(dentry_hash_lock)` block in `dentry_move()`;
5. leave `WITH_LOCK` and `fs/vfs/vfs_vnode.cc`'s `ASSERT(!vfs_dentry_hash_lock_held())` untouched;
6. rebuild with `DEBUG_VFS` on and re-run `tst-dentry-lock` plus the validation that originally proved
   #1502 (it cleared the VU32 dentry wedge end-to-end), then fill in the evidence line above.

BLAST RADIUS NOTE: `pr/vfs-dentry-perchain` (#1503) carries the same apparatus, widened to a per-chain
count (`.local/worktrees/dentry`, `a642706e2`: `__thread dentry_hash_lock_depth` incremented per chain
lock). There, `owned()` on a single mutex is NOT a drop-in substitute, because the predicate must be
"holds ANY chain lock" and a thread can hold several. Options for #1503, once #1502 settles:
(a) keep a count but derive it (`std::any_of` over `dentry_chain_lock[]` calling `owned()`) - no
    thread-local, still exact, O(DENTRY_CHAINS=32) and DEBUG_VFS-only so the cost is irrelevant; or
(b) keep the counter only in #1503 and justify it there as "multiple locks, so no single `owned()` works".
(a) is preferable and keeps nyh's point applied consistently. Do NOT rework #1503 until #1502 lands, so
the stacked diff stays reviewable.
