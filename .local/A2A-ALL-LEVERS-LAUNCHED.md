# The real A2A: OSv/PG vs Linux/PG with all levers on, matched hardware (agent 99c8421f)

## #1472 default flipped to ON (done first)
Committed 4dc03bbc9 on pr/sched-idle-pull (head now 4dc03bbc9, merge-clean vs master, disclosed at
issuecomment-5653482669). wake_pull_enabled = true by default; OSV_WAKE_PULL=0 now DISABLES (was: =1
enabled). Kconfig help updated. Env A/B preserved: unset->on, =0->off, =1->on. So a stock OSv build now
gets the +238% high-VU scaling automatically.

## The a2a base: gh-fork/bench/a2a-all-levers (head 17d814758), ALL levers on ONE base
    TCB psABI guards (stack_guard=3)          -- cbbf74e7
    fork RANGE_BS=2 + LARGE_SHARE=2           -- cbbf74e7
    idle-CPU pull work-stealing DEFAULT ON    -- 4dc03bbc9 cherry-picked
    fsync writeback-scan guard                -- 05d5d7944 cherry-picked (#1507)
    ZIL hires cv_timedwait fix                -- cbbf74e7 (via 7f080f25c/1dc86f42c)
Cherry-picks were clean; verified each marker present on the built source.

## ARC match decision: match on the LINUX side, not OSv
OSv patch 0031 caps ARC at half-RAM = 32 GiB on a 64 GiB guest. Rather than hand-edit the frozen OSv
base's ZFS patch (fragile - non-atomic git apply, and #1506's env knob targets master's osv/ layout not
this patch layout), MATCH THE LINUX SIDE: run Linux ZFS with zfs_arc_max=32GiB, proven binding. Final
tuple: 32 GiB ARC BOTH sides, 64 GiB RAM, 32 vCPU, same ashift/recordsize/GUCs/dataset. One variable = OS.
This is legitimate - matching may move either side as long as the final config is identical. #1506
remains a valid standalone PR for the general "cap OSv ARC to any value" case; it just is not needed here.

## The design: same m5d.metal, same physical NVMe, both OSes
OSv as KVM guest + Linux on the host (or matched VM), same instance-store NVMe, one driver. Truly
identical hardware - the only variable is the OS. This is how the iowake isolate got a clean comparison.

## The questions
1. Parity? ratio OSv/Linux at each VU, matched config.
2. SHAPE - does OSv SCALE now (WAKE_PULL on) instead of peaking at VU8 and declining? This is the
   headline test of the whole scheduler-fix thesis.
3. Residual gap (if any): wait histogram + %util + p99 name what gates it.
4. WAKE_PULL working: host per-CPU util most-busy under high VU (off=8-10, on=29-30).
p99 alongside every number (standing requirement). No historical Linux number reused - Linux measured
fresh with matched 32 GiB ARC.

## Two agents running in parallel, no collision
- 99c8421f: a2a benchmark (this) - owns bench/a2a-all-levers, tag Owner=agent-a2a3lever.
- bc56ff97: maintenance sweep (PRs/deps/upstream/sync/tidy) - read-mostly, told HANDS OFF the bench
  branches and any running agent-* box. Told not to touch new boxes.
