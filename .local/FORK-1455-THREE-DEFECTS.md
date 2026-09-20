# Three pre-existing defects in #1455, found while implementing the POSIX fd table

2026-09-10, agent a222d203. Each is independent, each blocks validating the next, and **all three are
pre-existing in #1455 rather than introduced by our work.**

## 1. `conf_fork=1` cannot link (build system)
`conf/kconfig/threads` declares `config fork` as plain `bool` + `default n`, with **no**
`def_bool $(shell,grep -q ^conf_fork=1 conf/base.mk ...)` hook - unlike every sibling
(`preempt`, `lazy_stack`, `lazy_stack_invariant`), which all have one. Meanwhile:

    Makefile:1666   ifeq ($(conf_fork),1) -> libc += process/fork.o     <- MAKE variable
    runtime.cc:3    #if !CONF_fork        -> defines fork()/vfork() stubs  <- KCONFIG symbol

Two independent switches that disagree, so `conf_fork=1` compiles both the real `fork()` and the stubs:

    ld.bfd: libc/process/fork.o: multiple definition of `fork'; runtime.o: first defined here

**So `./scripts/build conf_fork=1` cannot produce a kernel on that base**, while
`documentation/fork.md` tells readers to use exactly that. **No reviewer who tried the documented
command could have gotten it to link** - a plausible partial explanation for why the PR has sat.

## 2. The fork child never restores callee-saved registers (arch)
Verified at `dce0d32fd`:

    arch/x64/fork.cc:88-89   asm volatile ("movq %0, %%rsp \n\t")   // installs the stack, nothing else
    grep -cE "rbx|r12|r13|r14|r15"  at that SHA -> only rsp is touched
    same grep on our later branch               -> 8 matches (rbx, rbp, r12-r15 restored)

The child installs the copied stack but resumes with the **new thread's** callee-saved registers, while
the frame it lands on was compiled expecting the parent's. Anything the compiler spilled to a
callee-saved register across the `fork()` call is garbage in the child. The agent observed exactly that:
`RBX=0xc174a0`, a kernel pointer where an fd should be.

**This was fixed downstream and never backported.** Our later branch's `arch/x64/fork.cc` carries a long
comment about restoring the full callee-saved context and loading `rsp` last so the sequence cannot
clobber its own base pointer - that code exists because someone hit this. Same pattern as the fork
scan fix and the `.PHONY` fix: **work that exists but is not where it is needed.**

## 3. The shared global fd table (the original task)
POSIX requires the child to get a **copy** of the descriptor table where entries are independent but the
open file descriptions are **shared**. Baseline, all six rules failing on `dce0d32fd`, with the single
most useful line being:

    parent read after child's 10 bytes: n=4 first=0x41 pos=4 (expected n=4 first='K' pos=14)
      -- the offset is NOT shared

Plus the earlier salvaged crash: **`close()` in a child page-faults in `fdclose()`**, so the shared table
was not merely non-POSIX but unsafe under fork.

## Why the ordering is itself the argument for the PR
1. Without the kconfig hook, nothing links, so nothing is testable.
2. Without the register restore, the child resumes with corrupt state, so no fd test can be trusted.
3. Only then is the fd table's behaviour meaningful.

**Each fix is a prerequisite for validating the next**, which is presumably why the fd table appeared
broken in ways that had nothing to do with descriptors.

## Attribution discipline required before publishing
With two pre-existing bugs in play, **some of the six failures may be caused by register corruption
rather than by the shared table.** Asked for a **three-column BEFORE / +regfix / +fdtable** table - one
extra boot - so each fix gets credit for what it actually repairs. If they cannot be separated cleanly,
say so rather than crediting the fd table with everything.

#1455 stays DRAFT until all six pass, with an explicit gap list if any remain. Given two unrelated bugs
surfaced while doing this, a gap list will not read as failure.

## Results in, and a decision that needed a fourth measurement

Agent a222d203 delivered the three-column table I asked for:

    COL1  base dce0d32fd          guest CRASHES: page fault RIP=<fdclose(int)+24> via <close+23>
    COL2  kconfig + regfix        1/6 pass, and the one that passes is t2_offset_is_shared
    COL3  all three commits       6/6 pass

**COL2 is the column that earns its keep.** It proves the other five failures are the **shared table**,
not the register bug, and that `t2_offset_is_shared` passes *before* the fd change and **keeps** passing
after - which is exactly what a naive "duplicate everything" implementation would have broken. Without
COL2 the fd table would have been credited with all six.

## The regression, honestly reported
`tst-execve` **fails on commit 2** ("trying to execute or access missing symbol", no tests run) while
passing 3/3 on the base. Isolated to the register fix by running the middle-column image.

The discriminating detail is the valuable part: `tst-execve` calls `fork()` **directly from `main()`**,
whereas `tst-fork` calls it from a nested function - and `tst-fork` passes 10/10 on the same image
**including its own fork+execve of the same payload**. So the **outermost frame** is the special case,
and a **relocating** stack copy cannot serve it: it holds bias-sensitive state beyond the frame pointer
the agent had already stopped restoring.

Evidence that the restore itself is correct, not the problem: `fd=3` and `magic=0x5a5a5a5a` now arrive
intact where they were previously `12686400` and `0x1000`.

**The named fix is the argument, not the patch:** the downstream design copies the child stack at the
**same VA** with private physical pages (`mmu::clone_address_space`), so there is no bias and the
outermost frame needs no special handling. That reframes commit 2 from "an incomplete patch" into
**evidence that thread-backed fork with a relocating stack copy has a structural limit which the later
address-space design removes** - a real architectural argument about the PR.

## Why I refused the default option
The agent proposed defaulting to **(a) ship commits 1+3** (kconfig + fd table), dropping the register
fix. But:

    COL1  base                        CRASH
    COL2  kconfig + regfix            1/6
    COL3  kconfig + regfix + fdtable  6/6
    ----  kconfig + fdtable, NO regfix   <- NEVER MEASURED

**Option (a) would ship exactly that unmeasured pairing while claiming 6/6 for it.** Given the base
crashes in `fdclose()` and the register bug corrupts precisely the kind of value an fd test reads, some
of those six may pass only because the regfix is present. **One build and one boot resolves it**, so I
required the fourth column before the decision:
- **6/6** -> ship 1+3, claim the fd table stands alone, report commit 2 as diagnosed-but-unfixed.
- **fewer** -> the fd table depends on the regfix; ship all three with the `tst-execve` regression
  disclosed and say which tests need commit 2.

Either answer is publishable. Guessing between them is not - and this is the same error I have made
repeatedly this session by crediting a fix with a delta I had not isolated.

#1455 stays **DRAFT** either way: at 6/6 with a disclosed regression or a documented outermost-frame
limit, it is not ready to merge, and saying so is what makes the rest of the report credible.

## FINAL: the fourth column changed the answer, 0/6 not 6/6

Agent a222d203 complete. Box terminated, **0 orphans**, no orphan volumes. Published on **#1455**
(issuecomment-5624787989), branch `gh-fork/wip/fork-posix-fdtable-v5`, PR left **DRAFT**.

    aff774350 G  conf: make conf_fork actually enable fork(), it did not link
    2d4f1a270 G  fork: restore the caller's callee-saved registers in the child
    d181aa015 G  fs: give each fork() child its own POSIX file descriptor table

### The measured matrix

    base dce0d32fd         guest CRASH (fdclose page fault)   nothing testable
    +kconfig +regfix       1/6    t2_offset_is_shared passes => the regfix is sound
    +kconfig +fdtable      0/6    the fd table ALONE is worthless
    all three              6/6    the series is the unit

**Refusing the default was the right call, and by a wide margin.** The agent proposed shipping commits
1+3 and dropping the register fix; that combination measures **0/6**, so the PR would have claimed 6/6
for something that fixes nothing. **The fourth column cost one build and one boot and prevented a false
claim in a published PR.** This is the same class of error I made repeatedly this session - crediting a
fix with a delta I had not isolated - and it is the first time the guard caught it before publication
rather than after.

`t2_offset_is_shared` passing in column 2 **and staying passed** in column 4 is the other half: the
shared-offset property survives the fd change, which is precisely what a naive "duplicate everything"
implementation destroys.

### Honest gaps, disclosed in the PR
- **`tst-execve` regresses on commit 2** (3/3 -> fault), isolated to that commit alone by the column-4
  image; the fd table is uninvolved.
- **Root cause is frame depth, not execve**: `fork()` from `main()` faults, from a nested function works
  (`tst-fork` 10/10 including its own fork+exec on the same image). A **relocating** stack copy cannot
  serve an outermost frame. `mmu::clone_address_space` (same-VA, private physical pages) removes the bias
  entirely but does not exist at this base - so commit 2 is framed as **evidence of a structural limit**
  in thread-backed fork, not as a finished fix.
- No regressions elsewhere: `tst-pipe` 87/0, `tst-af-local` 30/0, `tst-fork` 10/10 both sides,
  `conf_fork=0` builds clean.

### The most consequential single finding for the PR's history
**`./scripts/build conf_fork=1` has never linked on that base** - `config fork` is a plain `bool` with no
`def_bool $(shell,...)` hook, so the make variable compiles `fork.o` while kconfig still emits
`runtime.cc`'s stubs: `multiple definition of 'fork'`. Verified on pristine `dce0d32fd`. **No reviewer who
followed `documentation/fork.md` could have built the feature**, which is a plausible explanation for why
#1455 sat with one unanswered question.

### Process note
The agent **reviewed the pre-existing implementation rather than trusting it**, which is how both
arch-level bugs surfaced. Had it accepted the working code as-is, the fd table would have been published
on top of a base that crashes and a child with corrupt registers.
