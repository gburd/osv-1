# Wake-time idle-CPU steering: PR routing + verdict

## Artifact
- Bundle: `sched-wake-idle-steer.bundle` (1 commit `9a6ba7ac`, author Greg Burd, Signed-off-by, --no-gpg-sign so you re-sign).
- Base: it STACKS ON #1464 `pr/sched-load-balance` tip `512b2b2ec5` ("sched: disperse threads faster in the load balancer"). Bundle range = `512b2b2ec..HEAD`. It does NOT apply on bare upstream/master; #1464 must be present first.
- Also pushed to gh-fork as `wip/wakesteer-benchbuild` (that branch is the fork-substrate build variant = #1458 6b71c76385 + #1464 + this fix, used only for the A/B bench; NOT the PR branch).
- Local worktree: `/home/gburd/ws/osv-wakesteer` branch `pr/sched-wake-idle-steer`.

## What it does
`thread::wake()` normally re-queues a blocked thread onto its home CPU. This adds a Linux
select_task_rq analog: when waking an unpinned application thread whose home CPU is loaded
while some CPU is idle, enqueue the wakeup on the idle CPU. Gated by build option
`sched_wake_idle_steer` (env `conf_sched_wake_idle_steer=0` disables). Confined to: app threads
only, wake() thread-context only (never IRQ wake_with_irq_disabled), old_status==waiting only
(not lock-handoff sending_lock), never the current thread, never pinned/migrate-disabled.
Runtime is exported from the HOME cpu scale.

## VERDICT: DO NOT OPEN AS A PR (negative result)
Measured A/B on m5d.metal, -smp48, PG18-on-ZFS-raidz1-local-NVMe, A=steer OFF (#1464 only)
vs B=steer ON. Full numbers in RESULT-wakesteer.txt. Two decisive reasons:

1. REDUNDANT FOR RO ON THE #1464 BASE. #1464's aggressive load_balance (10ms, drain the whole
   imbalance) ALREADY disperses the woken-backend clump: pre-#1464 the DEFINITIVE matched run
   had ~12k RO plateau on ~5 busy CPUs; with #1464 alone it is ~32k on 15 busy CPUs (top -H).
   Adding wake-steering leaves the RO curve unchanged (B/A ~= 1.00 at every c1..c64 cell). The
   clump wake-steering was meant to fix is already gone once #1464 is in.

2. WRITE-PATH LIVELOCK. With steering ON, pgbench -i at moderate scale (>= s50, and re-init at
   s20) livelocks (guest spins ~242% CPU, heavy concurrent COPY/index never finishes; steer OFF
   finishes s300 init in ~43s). RO is stable, RW is not. A known-livelock commit is not
   mergeable.

## Recommendation
- Ship #1464 (`pr/sched-load-balance`) as THE scheduler improvement for this plateau. It is the
  real lever (5 -> 15 busy CPUs, ~12k -> ~32k RO). It is already an approved standalone PR track.
- The residual gap (OSv ~32k vs Linux ~190k WITH #1464) is NOT wake-placement. Next levers to
  re-evaluate on the #1464 base: virtio-net multiqueue RX (now that idle CPUs exist for extra
  receiver threads to run on) + per-packet RX alloc removal. Those are the #1463/#1468 tracks.
- Keep this branch for the record only. If ever revisited, the RW livelock (migration ping-pong
  / lost-wakeup under a write storm from the unlocked load() read + eager per-wake migration)
  must be root-caused and fixed first, and it would still need to beat #1464 on RO to justify.
