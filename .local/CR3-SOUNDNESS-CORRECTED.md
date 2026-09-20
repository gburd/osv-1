# TLB local-flush soundness: corrected attribution and a stronger mechanism

2026-09-07. My original framing of this finding was wrong in its facts and weaker in its
mechanism. Corrected by agent 97dc21c0, verified by me. **The earlier version in
.local/THIRD-CAUSE-*.md and the session notes should not be quoted.**

## What I had wrong

I claimed: #1456 carries an `exception_depth >= 2` local-flush fast path, whose safety
rests on an invariant violated by `libc/signal.cc:718` injecting a handler thread into a
live fork child's AS via `as_for_pid`, plus `core/sched.cc:1382` making threads inherit
their creator's AS.

Measured reality:

    #1456 (wip/fork-stage2-pr)            flush_tlb_local: 0 occurrences
                                          flush_tlb_all at 565, 1232, 1457, 2097
                                          (the fault-path flush at 2097 is UNCONDITIONAL)
    #1475 (pr/fork-cow-nested-lockfree)   flush_tlb_local: 1  <- the fast path lives HERE
    as_for_pid in libc/signal.cc:  #1456: 0   #1475: 0   wip/fork-clone-scan: 5

Also: the sched.cc line is 1094 on these heads, not 1382. And #1475 is NOT stacked on
#1456 (`git merge-base --is-ancestor` says no).

Root cause of my error: I was reading my own integration branch (`wip/fork-clone-scan` /
`integ/pg-fork-zfs`) and attributing its contents to the PR heads. The signal.cc
cross-AS injection is real, but it is on neither PR head.

## The actual, stronger bug

#1456 `core/mmu.cc:398-403` write-protects the **parent's** PTEs, not just the child's:

    } else if (ppte.writable() && !pte_is_cow(ppte)) {
        // Private writable page: make it COW (write-protect + cow bit) in
        // BOTH parent and child.
        pt_element<0> cow = pte_mark_cow(ppte, true);
        parent_pt[i] = cow;
        child_pt[i] = cow;

Therefore the multi-threaded **parent** takes these COW faults, and the parent AS (AS0)
is shared by every non-forked thread on every CPU.

#1475 `core/mmu.cc:2022-2033` then justifies a local-only flush with:

    // only the faulting CPU can hold a stale write-protected TLB entry for addr
    // in this AS, and other CPUs run a different CR3 ...
    if (sched::exception_depth >= 2) { mmu::flush_tlb_local(); }
    else                             { mmu::flush_tlb_all(); }

"Other CPUs run a different CR3" is **false for AS0 by construction**.

Why it does not self-correct: the stale entry is *read-only present*, and a read against
a present entry does not fault. So a sibling thread on another CPU keeps reading the
pre-copy physical page and silently misses the writer's updates, until that CPU happens
to reload CR3 or the line is evicted. A stale *not-present* entry would fault and heal
itself; this one does not.

Interleaving: thread A on CPU0 faults, allocates a fresh phys page, updates the PTE,
flushes LOCALLY. Thread B on CPU1 in the same AS still holds the old read-only mapping
and reads stale data.

## Why this version is stronger than mine

1. It needs no signal path and no cross-AS thread injection.
2. It fires in the ordinary multi-threaded-parent case, not a PostgreSQL-specific one.
3. The unsound line is literally #1475's own, and #1475 is still DRAFT - the ideal place
   for a reviewer to act.

The fix is narrow: the `depth<=1` conservative `flush_tlb_all` is correct, so the guard
needs an additional condition - local flush is permissible only when the AS cannot be
live on another CPU, which the parent AS violates by construction.

## Venue

Posted on **#1475** (where the unsound line is), not #1456. The signal.cc/`as_for_pid`
observation is kept but filed where it actually lives (`wip/fork-clone-scan`,
`integ/pg-fork-zfs` / #1458), explicitly NOT claimed to be on #1475's head.

## Lesson (recurring)

Second time this session I attributed integration-branch content to a PR head. The guard
is the same one that caught the cherry-pick error: `git grep -c <symbol> <branch-head>`
per branch before writing any claim about which PR contains what. Cheap, decisive, and I
skipped it twice.
