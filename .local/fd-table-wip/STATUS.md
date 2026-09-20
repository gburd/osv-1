# CORRECTED 2026-09-10: "no implementation exists" was WRONG

An implementation **did** exist, uncommitted, in a **local worktree** at
`/home/gburd/ws/osv-fdt-wt` on branch `wip/fork-posix-fdtable`, based exactly on `dce0d32fd`. It
matched the design guidance closely: `fd_table` object, pointer in `sched::thread`, clone-on-fork with
`fhold` per open file, per-table-entry `FD_CLOEXEC` bitmap, threads inheriting their creator's pointer.

**My salvage checked only the EC2 box and the pushed branches**, concluded "no implementation exists",
and wrote that here. I have 23 worktrees and did not enumerate them. Agent a222d203 found it, **reviewed
it rather than trusting it**, committed it signed and pushed it off-box.

**Salvage procedure now needs a third step: check local worktrees, not just the box and the remotes.**

Also: the SHA in my brief had a doubled character (`dce0d32fdd59...`); the real head is
`dce0d32fd59a1f98c58ab3fa2c452e692538da6d`. Every other fact I stated about that SHA was confirmed
(gfdt=14, hooks=0, fork.cc=230 lines, no `address_space`).

---
# fd-table work-in-progress: salvaged from an orphaned agent box

2026-09-10. Agent `d532c5b7` exhausted its context and its record was cleared; its box
(`i-07285dc6797edc764`) was left running with **nothing pushed**. Salvaged before reclaiming.

## What EXISTS (salvaged here)
**`tst-fork-fdtable.cc` - 487 lines, all six POSIX rules**, matching the brief exactly:

    t1_child_close_does_not_close_parent
    t2_offset_is_shared              <- the half a naive "dup everything" fix breaks
    t3_independent_numbering
    t4_cloexec_is_private
    t5_refcount_lifetime
    t6_postmaster_death_watch        <- the regression the old hooks papered over

Its header comment states the distinction correctly: the table is copied, the open file descriptions
are shared, `FD_CLOEXEC` is per-descriptor while `O_NONBLOCK` and the offset are per-description. That
is the hard part of this task and it is done.

## What DOES NOT exist
**No implementation.** `grep -c fd_table fs/vfs/kern_descrip.cc include/osv/sched.hh` = **0, 0**. The
only tracked changes on the box were `apps`, `modules/tests/Makefile` and `modules/tests/module.py`
(build plumbing to ship the test). The agent died during its **baseline** run, before writing the fix -
which is the correct order, and it means the expensive part that remains is the implementation, not the
proof harness.

## The baseline evidence, which is better than expected (`baseline-crash.log`)
On #1455's head, the first POSIX test does not merely fail - **it crashes the guest**:

    OSv v0.57.0-386-gdce0d32f
    Cmdline: /tests/tst-fork-fdtable.so
    tst-fork-fdtable: POSIX per-process fd table across fork()
    page fault outside application, addr: 0x0000000046681000
    RIP: 0x00000000403b0698 <fdclose(int)+24>
    ...
    0x00000000403a98e7 <close+23>
    QEMU_EXIT=124  (timeout after the abort)

**So `close()` in a fork child faults in `fdclose()` on that base.** That is a much stronger
motivation than "semantics differ": the shared global table is not just non-POSIX, it is unsafe under
fork. It also independently corroborates why the later branch grew three `close()` special cases - they
were suppressing this.

## Value assessment
- The **test suite is the reusable asset** and it is complete.
- The **baseline crash is a publishable finding on its own**: it demonstrates the defect without needing
  the fix, and it is exactly what a reviewer asked about.
- Remaining work is the implementation: a descriptor-table object, a pointer in `sched::thread`, clone
  on fork with a reference per open file description, per-descriptor `FD_CLOEXEC`, and the
  fork-child-versus-`pthread_create` distinction (the crux on a base with no address spaces).

## Housekeeping
Box `i-07285dc6797edc764` terminated after salvage. **Third orphan of the session** - all three had
usable work on disk, and all three were recovered only because the box was inspected before being
reclaimed. Salvage-then-reclaim is now the standing order.
