# A new defect class: a published correction that was never landed

2026-09-08, found by agent d35a8d8c during maintenance round 10. Mine, and worse than the bug it
was correcting.

## What happened

On 2026-09-07 I found that PR **#1497**'s published verification table was wrong: it claimed the
placeholder path "still yields exactly one line" when it actually yields two. I:
- posted a correction comment with a measured table,
- created the corrected branch `pr/zfs-provider-manifest-v2` (`3f0c4579f`, the one-hunk
  `modules/zfs/usr.manifest` deletion),
- edited the PR body,
- and wrote **"Corrected branch: `pr/zfs-provider-manifest-v2`. I will repoint this PR to it."**

**I never repointed it.** The PR head stayed at `afcf5a7de`.

## Verified three ways before authorising the fix
1. `git merge-base --is-ancestor pr/zfs-provider-manifest pr/zfs-provider-manifest-v2` -> **strict
   fast-forward**, exactly one commit, no force required.
2. The published head **still ships `modules/zfs/usr.manifest`**; v2 removes it.
3. **Executed the resolver on the published head**: module list `zfs` -> **TOTAL libsolaris lines:
   2**. That is exactly the column of my own corrected table that I had labelled as the defect.

So #1497's body AND my correction comment both describe behaviour the code does not implement.

## Why this is worse than the original bug
A reviewer reading the thread would conclude the fix was in place. The original defect was a wrong
table; this is a **wrong table plus a promise of a fix that a reader has every reason to believe
landed**. It is precisely the failure mode I have been criticising all day in others' work and in
my own.

## Why no existing check catches it
- **Mergeability check**: passes. The branch merges cleanly.
- **Leak scan**: passes. Nothing sensitive.
- **Diff review**: passes. The diff is internally self-consistent.
- **CI**: would pass, since the code builds.
Only comparing **the PR thread against the PR head** reveals it. Nothing in the standing checklist
did that.

## Added to the standing maintenance checks
For every PR, search its comments for **"corrected branch"**, **"v2"**, **"I will repoint"**,
**"fixed in"** - that phrasing is the signature - and then verify the **head actually contains the
corrected code**. Authorised the agent to land any such case that is a **strict fast-forward**, and
to report rather than force anything divergent.

## Resolution
Authorised the ff push of `3f0c4579f`, with three requirements: verify the resolver output AFTER the
push (1 line for each of `zfs`, `open_zfs`, `zfs,zfs-tools`, `open_zfs,zfs,zfs-tools`) rather than
assuming; post a brief note on #1497 that the promised repoint has landed; and re-scan the body for
any surviving sentence describing the old behaviour.

## RESOLVED, and the audit found the defect was singular (so far)

#1497 fast-forwarded `afcf5a7de` -> `3f0c4579f`. Verified by me: head is now `3f0c4579f` and
`modules/zfs/usr.manifest` is **removed**, so the code finally matches both the body and my
correction comment. Note posted on the PR.

### The audit harness and its results
The agent built a harness flagging PRs whose comments contain correction-signature phrasing
("corrected branch", "v2", "I will repoint", "fixed in", "superseded by"). It flagged **6**:
#1497, #1449, #1447, #1476, #1467, #1439.

Cleared with evidence rather than by reading:
- **#1497** - the real defect. Fixed.
- **#1449** - the "superseded by #1489, please close" comment was itself retracted, and head
  `ba63c5725` genuinely carries both promised test fixes as a fast-forward of `b30f3acff`.
- **#1467** - both "fixed on this branch" claims verified present in code (`flush()` clears rather
  than deletes; `slow_path` dispatched after `rcu_read_unlock`).
Remaining for the follow-on agent: **#1447, #1476, #1439**.

### The `conf_fork=0` break: fixed on three branches, proven both ways
    wip/aarch64-boot-plus-elf-as-fix    761987065 -> ff7fba040   G
    fix/rofs-cache-fork-arena-coherence 5af7da0be -> 37e3912ac   G
    fix/elf-object-cache-address-space  6265b5ce5 -> 7aa9c577c   G
I verified the guard is now correctly placed (`#if CONF_fork` at 548, override at 549, `#endif` at
550) on all three.

**The agent did not use a reduced test case for the final proof.** It captured the project's real
`core/elf.cc` compile line via a `CXX` wrapper and built that TU through the actual Makefile:

    header state          conf_fork=0            conf_fork=1
    override unguarded    FAILS at elf.hh:548    compiles OK
    override guarded      compiles OK            compiles OK

**The bottom-right cell is the one that mattered** - a fix that silenced the `override` error while
breaking the fork build would have been worse than the bug. That is the discipline I want as
standard: **prove the check fails when the bug is present, or it is not a check.**

### Master-eligibility, settled properly
Nothing in `da3041f5d`/`6265b5ce5` is master-eligible. All 137 added lines are inside `#if CONF_fork`;
the fix exists *because* `program::_files` is process-global while PT_LOAD segments are per-AS, a
condition that cannot arise with one address space; and `mapped_in_current_address_space()` /
`remap_segments_in_current_address_space()` / `run_init_funcs_for_new_address_space()` are all
meaningless with a single AS.

The test was the one plausible early-landing candidate and it fails too: `tst-fork-dlopen-as.cc`
calls `fork()` directly, so on master it compiles against the `ENOSYS` stub. Decisive check:
`git ls-tree upstream/master tests/` matches **zero** `tst-fork-*` files and master's
`modules/tests/Makefile` has **0** occurrences of `tst-fork` - there is no fork-test scaffolding for
it to join. **The shippable-part instinct was right to check; there is no shippable part.**

### `conf_fork=0` as a routine check: cheap, recommended
One `make build/release.x64/core/elf.o conf_fork=0` per affected TU - seconds, no image, no boot.
Two prerequisites found by doing it: the worktree needs populated `musl/` + `musl_1.2.1/` submodules
and a `boost_base=`, and **some pre-existing `build/last` trees are root-owned from old builds**,
which is a separate cleanup I will handle rather than have an agent escalate privileges for.
