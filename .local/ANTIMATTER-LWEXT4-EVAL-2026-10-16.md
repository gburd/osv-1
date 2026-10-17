# antimatter-studios/lwext4: focused evaluation (2026-10-16)

Copyright (c) 2026 Greg Burd. BSD-3-Clause.

Question: switch our ext4 base to antimatter-studios/lwext4, curate a combined fork, or neither?
Would adopting it save us from writing roadmap D2.1 (journaling) / D2.2 (write perf, pagecache
bridge) ourselves?

## What the fork is

- **Author: Chris Thomas** (commits as "Chris Thomas" x164 + "Christopher Thomas" x67 +
  "lwext4 integration" x19). This is the SAME author as gkostka PRs #107/#111, which our #1533
  already backports. So it is the de-facto active lwext4 development line by a contributor we
  already trust, not a random fork.
- **Very young and solo:** all 482 commits are 2026-09-30..2026-10-16 (2.5 weeks), single author,
  0 stars, 0 forks, 1 open issue. No external review. gkostka upstream is dead since 2022-09, so
  this is effectively where lwext4 is being maintained now, but by one person for two weeks.
- **BSD-licensed** (lwext4's own license, same as upstream and osvunikernel) - clean for OSv.
- **Nature:** a hardening + test + portability layer, not a rewrite. src/include change is
  concentrated: ext4.c (+986/-199), ext4_dir.c (+222), ext4_blockdev.c (+151), ext4_balloc.c (+93),
  bitmap/bcache small. The bulk of the 482 commits is 43 test files, 41 platform ports, 14 ports,
  12 CI workflows, and 115 merge commits. It adds a real test/fuzz/memory suite and an 85%-line
  coverage CI floor - which lwext4 never had.

## What it fixes (the valuable core)

- **Journal robustness** (NOT journaling-as-a-feature): I/O errors while aborting/committing a
  transaction; two use-after-frees stopping the journal after write errors; a transaction bigger
  than the journal fails instead of asserting; a revoke count exceeding the block stops recovery;
  orphan-inode release on rw mount; "report write errors without a journal". These make the
  EXISTING journal code crash-safe; they do not turn journaling into an enabled write mode.
- **Extent / block map:** holes where a block must be mapped are an error not an assert; extent
  removal after a hole; byte-order fixes; depth-loop fix (#202). Overlaps and extends #1533.
- **Dir / htree:** htree split allocation refuses an in-use block; NULL-len guards. Overlaps #1449.
- **xattr:** ibody header validity, extra-isize, alignment, ext_attr feature gating.
- **Symlinks:** slow/fast symlink read and write correctness (direct write, zero-pad).
- **Multithread:** readlink nested-lock, bdif ph/bbuf lock - real concurrency fixes. (We run
  lwext4 single-threaded-ish today, but PG-on-ext4 would exercise this.)
- Includes the Aladdin-R-D-class fixes independently (and more thoroughly).

## Does it give us D2.1 / D2.2 for free? NO.

- **D2.1 (ext4 journaling, "integrate and make optional"):** our build pin (osvunikernel
  6f6d8f7c5) is literally "Disable journaling and link with -nodefaultlibs", and our libext layer
  says plainly "does not implement journal" (ext_vnops.cc:19). The gap is TWO-sided:
  1. the lwext4 journal code (which antimatter hardens), and
  2. the OSv-side wiring in modules/libext (enable JBD, hook ext4_journal_start/stop around
     writes, recovery on mount, config toggle, fsync semantics).
  antimatter removes risk from (1) - the journal code is now crash-safe and tested - but (2) is
  entirely ours to write regardless of which fork we use. So adopting antimatter makes D2.1
  SAFER and SMALLER, not free.
- **D2.2 (ext4 write performance, zero-copy pagecache bridge reusing the ZFS ARC bridge):** this
  is an OSv-side concern (modules/libext read/write path + the pagecache bridge), not an lwext4
  concern. antimatter does nothing for it. D2.2 remains fully ours.

## Recommendation: do NOT switch the base now; curate, and plan a managed adoption

Switching our pin to a 2.5-week-old single-author unreviewed fork wholesale would:
- trade a stable, known base (osvunikernel 6f6d8f7c5 + our 2 reviewed patches) for a large moving
  target we cannot independently vouch for, and
- pull in 41 platform ports / 14 ports / CI we do not need, enlarging our build surface.

Better path, in order:
1. **Now (small, safe):** keep osvunikernel/lwext4 as the pinned base; add the vetted Aladdin
   subset (bitmap OOB write + the two cheap guards) as patch 0002, credited. This is the #1533
   follow-up already agreed.
2. **Soon (a focused task):** cherry-pick the antimatter fixes that matter for OUR usage - the
   extent/dir/symlink/xattr correctness and the multithread locks - as additional reviewed patches
   on our pin, each credited and each with a red/green test (antimatter ships the tests, so we can
   lift the test with the fix). Prefer this over a base swap: we stay curator, each fix is reviewed
   through our interface, and we track provenance.
3. **If/when we commit to D2.1 journaling:** at that point re-pin to a FROZEN antimatter commit
   (an exact sha, as #1500 does), because by then we want its hardened journal wholesale rather
   than cherry-picking a dozen journal commits. Gate it hard: enable journaling in the build, wire
   the OSv libext journal integration, and run antimatter's journal I/O-error and recovery tests
   plus our own crafted-image and PG-on-ext4 tests. Treat the re-pin as its own PR.
4. **Engage upstream:** since Chris Thomas is both the antimatter author and the gkostka #107/#111
   author, the cleanest long-term outcome is that this work lands back in gkostka or a blessed
   fork. Worth a note to him referencing our #1533/#1449 and that OSv consumes lwext4, so our
   needs (crafted-image robustness, single-glibc-ABI musl build, journaling toggle) are on his
   radar. Low effort, high leverage.

Net: antimatter is the right SOURCE to mine and the right eventual base for D2.1, but we curate
patches on our stable pin now rather than swap the base under a young solo fork. It shrinks D2.1
and de-risks it; it does not eliminate D2.1 or touch D2.2.
