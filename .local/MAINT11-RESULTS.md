# Maintenance round 11: seven of my premises corrected, one unanswered reviewer question found

2026-09-10, agent de0d45fd. No EC2 launched, nothing deleted ambiguously, no force-push.

## The find that mattered most: an unanswered human question, 4 comments deep

**#1455, `nyh`:** "won't you have problems with typical code which assumes the parent and child have
different file descriptors... Can you give me an example of an application where this is useful?"
**Four gburd comments existed afterward and none of them answered it.** That is the failure mode the
three-way audit exists to catch, except here it was a plain unanswered question rather than a stale
claim.

The agent answered it honestly (issuecomment-5618061647), built on pasted code
(`gfdt[FDMAX]` global table at `fs/vfs/kern_descrip.cc:41-45`), **retracting its own over-strong
`system()`/`popen()` claim** and stating outright that it cannot name an application that works today
and needs POSIX fd semantics.

**My decision: I converted #1455 to DRAFT** (issuecomment-5618232131). Asking for review of a
`fork()` PR whose fd semantics are a subset I could only describe after being asked is not fair to a
reviewer. The sibling fixes it exposed have landed or been filed independently, which is the argument
for holding it rather than a reason to rush it.

## Seven premise corrections, all verified
1. **`gkostka/lwext4#100` is an ISSUE, not a PR** (`pulls/100` -> 404). Status as expected: OPEN, 0
   comments, upstream's last push 2024-03-22, so **no reply is owed**.
2. **`osv-apps#72` is closed because it was MERGED** (`merged_at` 2026-07-05, `0b98404fe`) - a completed
   contribution, not outstanding work. Three items open, not four.
3. **`wip/forkroot-arm-base` is not "aarch64 fork fixes"** - its tip is the same `core/mmu.cc`
   largeshare commit as x86, and its three real aarch64 fixes are **already filed** as #1493/#1491/#1490.
4. **The NUMA conflicts on #1438/#1441/#1445 are REAL** - upstream **merged** NUMA discovery as
   `a92c44f9b` (verified: it is an ancestor of `upstream/master`). Add/add against our own merged work.
5. **#1475/#1456's `libc/signal.cc` conflict is REAL and is GOOD NEWS** - upstream merged **our own
   fix** as `6c9d0489b` (verified ancestor). The branches carry a duplicate; a rebase drops it.
6. **`wip/forkroot-arm-base` carries the trap pin `b38b99cd`** - the PG-free-image pin, on the aarch64
   benchmark base.
7. **`arnold` has 5 unpushed commits, not 23** - the 23/69-file/+19,368 figure is the full Mar-Apr
   window, most of it already pushed.

**So five of the nine "conflicts" are upstream taking our work.** That reframes them from defects to
rebase chores, and it is the single most encouraging thing in this report.

## A new three-way defect, caught by scanning 5,479 lines of commit messages
**#1503's title said "per-bucket locks" while its commit message and code say "per-chain"** -
`DENTRY_CHAINS = DENTRY_BUCKETS + 1`, because the fake chain for unlinked-but-referenced dentries gets
its own lock. The title **undercounted the lock array**. Fixed. Everything previously flagged
re-verified as still correct, including #1497's placeholder deletion checked in code rather than prose.

## What I fixed myself
**Both trap pins re-pinned to `5cb1903`**, G-signed, pushed to NEW branches (never force):

    wip/forkroot-arm-base  -> wip/forkroot-arm-base-repinned   (c7bb278bf, G)
    integ/pg-fork-zfs      -> integ/pg-fork-zfs-repinned       (d3e9e973d, G)

A nuance worth recording: **`b01994d04` IS an ancestor of `integ/pg-fork-zfs`**, so my earlier fix was
real - but it cured the **dangling** pin (`57c6079` -> `b38b99cd`) and `b38b99cd` is **itself** the
shadowed-build trap. Two different defects in the same field; fixing one did not fix the other.

## Dependencies: nothing to do, verified rather than assumed
    OpenZFS 71a9f9578 = zfs-2.4.4^{}  (#1488) | 83020cf82 = zfs-2.4.3^{} (master) | no 2.4.5 exists
    lwext4  #1500's pin == fork HEAD exactly
    musl_1.2.1 = v1.2.1 exactly (real musl v1.2.6, a deliberate tag pin)
    acpica, kbuild == pins
`osv/master` is `0 0` against `upstream/master` - already in sync.

## Tidy
Worktrees **24 -> 19**; git refused 3 more because they contain submodules and the agent **did not
force**. All **3 sole anchors re-verified** with `for-each-ref --contains` = 0 and preserved.
`rxpool-wt` (40 unpushed, 2767 dirty) and `fork-arena` (41/90) preserved. `/tmp/gitsign` kept, plus
`cprobe.c` because it is the probe source behind the latency result. **EC2: 0 orphans**; the live
`agent-stackchk` box untouched; all 6 unattached volumes and 11 snapshots are `solnix`.

**`arnold`: assessment is "nothing worth landing."** The Rust `crucible-osv` is a **77-line stub
returning ENODEV**, superseded by #1424's real C++ driver; the OpenZFS work is patch-file-based against
2.3.6 versus master's in-tree platform layer at 2.4.3. Preserved anyway, not deleted.

## Open for me
- **Rebases now available** on #1438/#1441/#1445 and #1475/#1456 - all five are "upstream took our
  work", not defects.
- **#1464 is APPROVED, MERGEABLE and clean** - the obvious first merge whenever the maintainer returns.
