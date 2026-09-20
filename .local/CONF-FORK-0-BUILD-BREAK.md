# Latent build break: `conf_fork=0` does not compile on the elf-fix branches

2026-09-08, found by agent d35a8d8c during maintenance round 10. Nothing published is broken, but it
would have landed the moment the elf fix merged toward #1456.

## The defect

`da3041f5d` adds `has_backing_file()` asymmetrically in `include/osv/elf.hh`:

    376  #if CONF_fork
    380      virtual bool has_backing_file() const { return false; }   // class object, INSIDE guard
    386  #endif
    ...
    544  class file : public object {
    548      virtual bool has_backing_file() const override { return true; }   // NO guard

With `CONF_fork == 0` the base declaration vanishes and the derived one still says `override`, so the
header does not compile. Reproduced by me in the project's dialect rather than reasoned about:

    $ g++ -std=gnu++14 -c /tmp/ovtest.cc
    error: 'virtual bool file::has_backing_file() const' marked 'override', but does not override

## Scope, verified per branch
Present: `fix/elf-object-cache-address-space`, `fix/rofs-cache-fork-arena-coherence`,
`wip/aarch64-boot-plus-elf-as-fix`.
Absent: `wip/fork-stage2-pr` (#1456), `pr/fork-cow-nested-lockfree` (#1475), and `da3041f5d` is not
an ancestor of #1456. **So no open PR is affected and nothing published is broken.**

## Fix authorised
One line: move the `class file` override inside `#if CONF_fork` on all three branches. Required the
agent to **prove it both ways** - compile with `conf_fork=0` AND `conf_fork=1` - because a fix that
silences the `override` error while breaking the fork build would be worse than the bug. Noted on
#1456, where the break would land on merge.

## Why no existing check caught it, and the pattern this completes
**The branch has only ever been built with `conf_fork=1`.** A conditional-compilation break in a
config nobody exercises is invisible to review, to the leak scan, to `merge-tree`, and to the builds
we actually run.

That is the third instance today of the same shape: **an artifact that is internally self-consistent
and wrong only relative to something nobody checks.**
1. **#1497's verification table** - self-consistent, contradicted only by executing the resolver.
2. **The unlanded correction** - thread and head each coherent alone, mismatched only when compared.
3. **This break** - compiles and passes everything, in the one config nobody builds.

Recommended `conf_fork=0` be exercised as a build config before any of these branches merge, and
asked whether that is cheap to add.

## Eligibility determinations accepted (and the evidence is the right kind)
`fix/rofs-cache-fork-arena-coherence` is **fork-only by construction**: its entire body is
`fork_arena::kernel_heap_scope` plus an include, `git grep kernel_heap_scope upstream/master` returns
nothing, and `git ls-tree upstream/master core/fork_arena.cc include/osv/fork_arena.hh` is empty. So
it is a no-op without fork and there is no master-eligible content to split out. That is a far
stronger argument than "it probably needs fork", and it is the standard I want for every
eligibility call.
