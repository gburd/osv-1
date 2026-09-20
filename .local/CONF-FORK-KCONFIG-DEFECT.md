# `conf_fork=1` cannot link on #1455's base: two switches that disagree

2026-09-10, found by agent a222d203, verified independently by me. **Pre-existing in #1455, not
introduced by our work**, and it may explain why that PR has sat.

## The defect

    conf/kconfig/threads @ dce0d32fd:
      config fork
        bool                <- plain bool
        default n
      config preempt
        def_bool $(shell,grep -q ^conf_preempt=1 conf/base.mk && echo y || echo n)
      config lazy_stack
        def_bool $(shell,grep -q ^conf_lazy_stack=1 conf/base.mk && echo y || echo n)

**Every sibling option has the shell hook; `fork` alone does not.** Meanwhile:

    Makefile:1666   ifeq ($(conf_fork),1) -> libc += process/fork.o      <- the MAKE variable
    runtime.cc:3    #if !CONF_fork        -> defines fork()/vfork() stubs   <- the KCONFIG symbol

So `conf_fork=1` sets the make variable (compiling `fork.o`) but leaves `CONF_fork` **unset** in
kconfig (compiling the stubs too), giving:

    ld.bfd: libc/process/fork.o: multiple definition of `fork';
            runtime.o: first defined here          (same for vfork)

**`./scripts/build conf_fork=1` therefore cannot produce a kernel at all on that base.**

## Why this matters beyond the build
`documentation/fork.md` tells a reader to use `conf_fork=1`. **So the documented way to enable the
feature does not link, and no reviewer who tried it could have gotten it to build.** That is worth
reporting on its own, independent of the fd table, and it is a plausible partial explanation for why
#1455 has had little movement.

## Instructions issued
- Fix as **its own commit, first in the series**, so the fd-table work sits on a base that builds.
- **Match the sibling pattern exactly** (`def_bool $(shell,...)` plus the `conf_base.mk` line if that is
  what siblings do) rather than inventing one, and say which sibling was copied.
- **Verify on the PRISTINE base first** and paste the actual `ld.bfd: multiple definition of 'fork'`
  output, so the report can state "this fails before any change of mine". That pre-existing-versus-
  introduced distinction is the entire value of the finding.
- **Then confirm `conf_fork=0` still builds clean.** The point of the hook is that BOTH settings work; a
  fix that makes `=1` link while breaking `=0` is a regression, and this project broke exactly that once
  by guarding a declaration but not its override. **Paste both build results.**
- Report on #1455 as a **distinct item**, worded as a build-system defect rather than a criticism: "the
  documented way to enable this feature does not link, here is the one-line hook its siblings already
  have."

## Remaining deliverable on that task
The **before/after test evidence for the six POSIX rules**. `t2_offset_is_shared` is the gate: it is the
property a refcount-based clone preserves and a naive copy destroys, and it must be shown with pasted
output rather than inferred from reading the code. #1455 stays DRAFT until all six pass.
