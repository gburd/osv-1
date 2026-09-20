# DRAFT reply - PR #1508, @nyh review 5260899871 (CHANGES_REQUESTED, submitted 2026-09-20T15:18:30Z)

STATUS: **DO NOT POST YET** - needs your judgment on the headline question (keep physio() or delete it),
and on the two pre-existing bugs he wants addressed or explicitly declined. The review is SUBMITTED, so
replying is mechanically safe; it is the CONTENT that needs your call, not the timing.

PR: "vfs: issue one bio per iovec in physio(), with the correct length". Now `reviewDecision=CHANGES_REQUESTED`,
and note `mergeable` flipped to UNKNOWN (GitHub recomputing; not a real conflict as of this sweep).

## GOOD NEWS FIRST: his central code request is ALREADY IMPLEMENTED

`pr/physio-per-iovec-v2` (local, unfiled, merge-clean) = `ce54c5cb3` (the filed commit) + `1b9b5add8`
"vfs: implement physio() with bdev_strategy_rw()", G-signed, committed 11:16 EDT today. Its physio() is:

```c
physio(struct device *dev, struct uio *uio, int ioflags)
{
	if (uio->uio_offset < 0)
		return EINVAL;
	if (uio->uio_resid == 0)
		return 0;

	return bdev_strategy_rw(dev, uio,
	    uio->uio_rw == UIO_READ ? BIO_READ : BIO_WRITE);
}
```

That is character-for-character the body he proposed in comment 4057265215. It also removes the
history-lesson comment block he objects to in 4057258154, and it inherits `bdev_strategy_rw()`'s
`uio_iovcnt > 0` loop guard, which is the OOB-read fix he asked for. So comments 1 and 2 are fully
answered by pushing that commit. Comment 3 (bounds check) and the "should physio exist at all" question
are NOT yet answered - see below.

---

## Reply to 4057265215 (physio should just call bdev_strategy_rw) - AGREE, done

> After the fix, physio() is character-for-character `bdev_strategy_rw()` with `bio_cmd` derived from
> `uio_rw`. So the whole function can be: [...] Moreover, using `bdev_strategy_rw()` will fix another bug -
> this version is missing a `uio_iovcnt > 0` check [...] Trading a hang for an OOB read is a step sideways.

Agreed on both, and the second point is the important one - thank you for catching it. Reimplementing the
loop was the wrong call; `physio()` is now exactly the wrapper you wrote (pushed as a follow-on commit).

On the OOB read specifically, you are right that my version made it reachable rather than merely latent.
`bdev_strategy_rw()` (`fs/vfs/vfs_bdev.cc:55`) loops on `uio->uio_resid > 0 && uio->uio_iovcnt > 0`, while
mine kept `physio()`'s bare `uio_resid > 0`. Before my change a zero-length leading iovec spun forever, so
the loop never reached the end of the array; after adding the `continue` that advances `uio_iov`, a uio
whose `uio_resid` disagrees with its iovec list walks past `uio_iov[uio_iovcnt-1]` and dereferences
whatever follows. Calling `bdev_strategy_rw()` removes my duplicate loop and the defect with it.

---

## Reply to 4057258154 (no history lessons in comments) - AGREE, removed

> Please ask your AI to avoid writing history lessons or changelogs in comments. The comment, if needed,
> should explain why some surprising code is correct - it shouldn't explain why one random mistake (which
> happens to be a mistake that existed in this code previously) is indeed a mistake.

Fair, and taken as a general rule, not just here. The "what used to be wrong" narrative belongs in the
commit message, where the history is the point; a reader of the code wants to know why the code in front of
them is correct. The block is gone - with `physio()` reduced to a call into `bdev_strategy_rw()` there is
nothing surprising left to explain, so it needs no comment at all.

---

## Reply to 4057273007 (missing bounds check) - AGREE it is a real gap; NEEDS YOUR DECISION on scope

> No bounds check. bdev_read/bdev_write both reject uio_offset + uio_resid > dev->size; physio() doesn't.
> #1424 makes it a real device read/write entry point, so out-of-range I/O would go straight at the driver.
> Worth adding deliberately or noting why not.

Confirmed: `bdev_read()` (`fs/vfs/vfs_bdev.cc:97`) and `bdev_write()` both do
`if (uio->uio_offset + uio->uio_resid > dev->size) return EIO;` and `physio()` has never had it. You are
right that this stops being academic the moment #1424 makes `physio()` a live entry point.

<OPERATOR DECISION - pick one>
(a) ADD IT: mirror the `bdev_read()` check in `physio()` (`> dev->size` -> `EIO`), one line, same errno as
    its siblings, and say so here. Cleanest, and makes physio() consistent with the rest of the file.
(b) FOLD IT INTO bdev_strategy_rw(): put the check in the shared helper so `physio()`, `bdev_read()` and
    `bdev_write()` cannot diverge again. Larger blast radius (touches the two callers' behaviour ordering),
    so probably a separate commit if we do it.
(c) If physio() is DELETED (see below), the question dissolves.
My recommendation: (a) in this PR if physio survives, with (b) noted as a follow-up.

---

## Reply to the review body - the real question: should physio() exist at all?

> #1424's comment says it "MUST go through physio() rather than bdev_read/bdev_write - those route through
> the OSv buf cache which is hard-coded to BSIZE=512". That's stale since his own c8c15304 [...] So it's
> worth asking whether physio() needs to be revived at all, or whether the Crucible driver should just use
> bdev_read/bdev_write and physio() should be deleted - 13 years dead is a decent argument for removal.

**He is right that my #1424 justification is stale, and I should say so plainly.** Verified against my own
commit `c8c153047` ("vfs: async device I/O via strategy fan-out, fix unaligned bdev paths", 2026-07-04):
`bdev_read()` now takes `bdev_strategy_rw()` whenever `bdev_uio_sector_aligned(uio)` holds
(`fs/vfs/vfs_bdev.cc:104-105`) and only falls back to `bread()`/the buffer cache for an unaligned offset or
a sub-sector length. So the claim that `bdev_read`/`bdev_write` *must* drag a 4096-block volume through a
BSIZE=512 buffer cache is no longer true for the aligned case, and for a 512-aligned-but-not-4096-aligned
request both paths reach the driver and both get the same `EINVAL`. The comment in #1424 describes the code
as it was before `c8c15304`, not as it is.

<OPERATOR DECISION - this is the one to make>
The honest options, with what I can verify:
(1) **DELETE physio()** and point Crucible at `bdev_read`/`bdev_write`. Strongest argument: after the
    rewrite `physio()` is a 6-line wrapper whose only distinguishing behaviour is that it SKIPS the
    `dev->size` bounds check its siblings do - i.e. its only unique property is a bug. If nothing else in
    the tree calls it, "13 years dead" plus "now redundant" is a clean case for removal, and it deletes
    both open questions (bounds check, comment) instead of answering them.
    CALLER AUDIT - DONE THIS SWEEP, and it supports deletion:
      * in `upstream/master`, `physio()` has **ZERO callers**. The only references are its definition
        (`fs/vfs/vfs_bdev.cc:182`) and its declaration (`include/osv/device.h:206`).
      * the other `physio` hits are unrelated: `vdev_disk_physio()` (a different function) and
        `bsd/.../zfs/zvol.c`'s calls to the classic BSD 6-arg `physio(zvol_strategy, NULL, dev, B_READ, ...)`,
        which is a different signature entirely - and `zvol.c` is not in the build.
      * the ONLY real caller is #1424's Crucible driver: `crucible_read()` and `crucible_write()` in
        `drivers/crucible-blk.cc:217,228`, each a one-line `return physio(dev, uio, ioflags);`.
    So "delete physio(), have Crucible call bdev_read/bdev_write" is a 2-line change in the driver plus a
    deletion, with no other in-tree fallout.
    AND THE CRUCIBLE COMMENT IS STALE TWICE OVER, not once - worth conceding both:
      * the buffer-cache claim, as he says, is stale since `c8c153047`;
      * it also says "physio() hands the whole uio to crucible_strategy() as a single bio, which is what we
        actually want anyway: one upstairs round trip per logical I/O" - but issuing ONE bio for a
        multi-iovec uio is precisely the bug #1508 exists to fix (that bio described `uio_resid` bytes at
        `iov[0].iov_base`). The behaviour the comment advertises as desirable was the defect.
    Remaining check before deleting: confirm Crucible's 4096-block volumes always present
    sector-aligned uios so `bdev_read`/`bdev_write` take the `bdev_strategy_rw()` fast path
    (`fs/vfs/vfs_bdev.cc:104`) rather than the `bread()` buffer-cache fallback. If an unaligned uio can
    reach the driver, `bdev_read` would route it through BSIZE=512 `bread()` and the original #1424 worry
    becomes real again for that case - that is the one scenario in which physio() (or an explicit
    `bdev_strategy_rw()` call) still earns its keep.
(2) **KEEP physio()** as the thin wrapper, add the bounds check, and correct the #1424 comment. Justify it
    only as "the traditional BSD raw-device entry point that external/ported code expects to find", which
    is a real but weak reason, and say the strong reason (buffer-cache bypass) no longer applies.
My recommendation: (1). The caller audit came back clean (zero in-tree callers; one caller, #1424's own
driver, needing a 2-line change), his argument is correct, and option (2) preserves a function whose sole
remaining difference from `bdev_read` is a missing safety check. But this changes #1424's shape too, so it
is your call, not mine.

Either way the reply must open by conceding the stale justification - that is the honest and the
credibility-preserving move, and he verified it against my own commit.

---

## What to do before posting

1. Decide (1) vs (2) above, and (a)/(b)/(c) on the bounds check.
2. If KEEP: push `pr/physio-per-iovec-v2` (adds `1b9b5add8`) to the #1508 head, plus the bounds-check line.
   If DELETE: close #1508 with the explanation, and open the deletion against #1424's needs instead.
3. The caller audit is DONE (see above): zero callers in master, one caller (#1424's Crucible driver).
   Still to confirm: whether Crucible can present an unaligned uio.
4. Then post: three in-thread replies + one top-level answering the "does physio need to exist" question.
