# Campaign 7: the benchmark finally launches on a base with every known blocker fixed

2026-09-10. Two agents in parallel: `2e50611c` (benchmark) and `04d7fc08` (maintenance).

## Why this attempt is different from the previous five
Every prior attempt died on a guest bug, not on methodology. **All three are now fixed and I verified
the base carries them:**

    gh-fork/fix/tcb-psabi-guards
      stack_guard in arch/x64/arch-tls.hh   3   <- psABI TCB fix (PR #1504)
      OSV_FORK_RANGE_BS in core/mmu.cc      2   <- fork range-scan fix
      OSV_FORK_LARGE_SHARE in core/mmu.cc   2   <- fork large-page sharing fix

The TCB fix is the unblocker: `thread_control_block` was 24 bytes while the x86-64 psABI puts the canary
at `%fs:0x28` (40), so every application canary check was an **out-of-bounds heap read**, aborting with
`__stack_chk_fail` after **1-5 cumulative forks** - fatal for a TPROC-C run needing hundreds of backend
spawns. That fix came from salvaging an orphaned agent's box.

For aarch64 I established the defect **does not apply**: its TCB is 2 words and GCC there reads the
`__stack_chk_guard` global rather than a TLS slot (no `-mstack-protector-guard=` flag is passed
anywhere). So `wip/forkroot-arm-base-repinned` should not need it, but the agent must confirm no
`__stack_chk_fail` abort before sweeping.

## Capacity, for the first time in this campaign, is not the constraint
    in use: 88 / 640  =>  552 free
    full matrix (m5d.metal 96 + c7gd.metal 64 + 2 drivers 32 = 192) FITS
So arms 1 and 2 run in **parallel** with separate drivers rather than sequentially.

## The question this run exists to answer
Connect latency is already solved on both ISAs (aarch64 117.3 -> 3.98 ms, at Linux parity; x86
56.9 -> 6.6 ms same-binary A/B, mechanism matched to 0.1% via hardware-independent `n_ptes` counters).
**Throughput has never been measured on a fixed base.**

    Linux (matched: 32 logical CPUs, musl, metal, ARC capped 16 GiB proven binding)
      VU8 213,505 | VU32 510,367 | VU64 614,277 PEAK | VU96 547,813   <- SCALES to VU64
    OSv old x86 base
      VU8  43,407 -> VU96 26,047                                       <- peaked at VU8
    gap: 4.9x at VU8 widening to 21.6x at VU64

**Do the fork and TCB fixes change the SHAPE, or only the level?** That is the difference between "OSv is
slower" and "OSv does not scale", and it is the one number that places M1 parity. Ratios must carry their
VU level; a bare "Nx" is meaningless when it quadruples across a sweep.

## Every substrate footgun is in the brief
Including the ones learned since the last attempt: `--use-openzfs` not `conf_zfs=openzfs`,
`upload_manifest.py` hardcoding `-m 4G`, `fs=rofs` ~119 MB with the PG-free signature at ~8 MB, no
`zfs-2.4.1-osv` banner (prove OpenZFS build-time), `seed_copy` strictly after `zfs mount`, pool created
once then import-only, `vhost=off`, no `--norandom`, `zpool get ashift`, `vucomplete` not `runtimer`,
rotate xtprof per run, apps at `5cb1903` re-checked after any submodule op, and
`state='active'` != on CPU.

## Anti-orphan measure
**Four agents have now died of context exhaustion with unpushed work on a box.** Both briefs require
pushing or writing results off-box **as soon as they exist**, and to report rather than continue if
running long. Every salvage so far recovered real work only because the box was inspected before
termination - salvage-then-reclaim remains the standing order.
