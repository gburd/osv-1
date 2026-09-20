# RX softirq / bottom-half design plan (2026-08-24, Plan agent)

## Core conclusion
OSv already HAS the correct bottom-half context: the per-rxqueue `net::receiver()`
poll thread (kernel thread, preemptable, !is_app(), pinned per-CPU, may allocate,
net_channel::wake/post_packet legal). The inline-RX deadlock is because the code
tried to do the poll-thread's post_packet/wake work INLINE in the ISR on an app
thread's stack (illegal nesting) -> wake_impl CAS-drop against the interrupted
app thread -> lost wakeup -> all CPUs do_idle.

FIX IS STRUCTURAL, NOT A NEW SUBSYSTEM: reduce the ISR to a pure top-half
(disable_interrupts + poll_task->wake_with_irq_disabled, NO net_channel work,
NO alloc), and route ALL drain + post_packet + net_channel::wake to the poll
thread, restructured NAPI-style (bounded budget + self-reschedule).

## Mechanism choice
- REJECT extending async.cc (run_later allocates + wakes IRQ-enabled -> illegal from ISR).
- REJECT a brand-new per-CPU softirq thread (redundant: receiver() already IS one).
- CHOOSE: reuse/generalize receiver() as the RX bottom-half. FreeBSD-netisr / Linux-NAPI split.

## The lost-wakeup-proof handoff
ISR (top-half): disable_interrupts(); poll_task->wake_with_irq_disabled();  (the ONLY wake in the ISR; legal because poll thread is !is_app() and IRQs off).
Poll thread: bounded drain, deliver via post_packet/net_channel::wake in its legal context;
when ring empty do the existing enable-then-recheck barrier (virtio-net.cc:634-643):
  enable_interrupts(); atomic_thread_fence(seq_cst);
  if (used_ring_not_empty() || !deferred->empty()) { disable_interrupts(); loop }
  else wait_until.
No wake lost: a race-in-before-enable is caught by the post-fence recheck; a
race-in-after-enable re-raises the (unmasked) MSI-X edge -> ISR re-wakes poll.

## Why current code loses the wake (sched.cc:1591-1595)
wake_impl drops the wake if the target thread is not in an allowed initial state.
Issuing net_channel::wake from the ISR nested on an interrupted app thread that is
itself mid-scheduler-transition -> CAS-drop -> backend never scheduled. Running the
wake from the clean poll-thread stack -> backend is in status::waiting -> CAS succeeds.
net_channel delivery can NEVER be done in raw IRQ; it MUST always defer.

## What runs where
ISR: disable_interrupts + raise softirq only.
Bottom-half (poll thread): get_buf drain, fill_rx_ring, packet_to_mbuf (m_gethdr/malloc),
post_packet->classify->push->net_channel::wake->wake_pollers(RCU)->epoll_wake_in_rcu,
generic if_input/netisr slow path.

## Changes (all in drivers/virtio-net.cc / .hh)
- MSI-X binding lambda (virtio-net.cc:423-448): reduce to disable_interrupts(); poll->wake_with_irq_disabled(); DROP the inline rx_drain(...true).
- add u32 net::rx_poll_weight() (budget mirror of rx_inline_weight).
- restructure net::receiver() (virtio-net.cc:623): bounded loop, `more = rx_drain(rxq, weight, false); if (more) poll_task->wake();` before wait_until. rx_drain always inline_ctx=false now.
- rx_drain inline_ctx==true branch (690-704) + deferred ring become dead for default path; retain for optional DIRECTWAKE experiment.
- NO core/ changes for default path (only removing ISR call sites of post_packet/net_channel::wake). Driver-local => upstreamable standalone.

## CONF_fork correctness
No IRQ alloc (all in poll thread); classifier hashtable + net_channel._pollers/_epollers already NET_SHARED_KH identity-heap; rxq/deferred/poll-stack are kernel allocs (pre-fork). Strictly SAFER than current inline path.

## Gating
OSV_RX_INLINE master switch: 0 = OFF = byte-identical today's poll-thread-wake path.
Non-zero = enable NAPI-poll bottom-half with that budget. Optional ISR peek behind
SEPARATE OSV_RX_DIRECTWAKE gate, default OFF, #if CONF_fork, single-thread-wake only,
NO wake_pollers in ISR. #if CONF_fork gating preserved; conf_fork=0 byte-identical.

## Test plan
Unit/smoke (ramfs, CONF_fork=1): tst-net_if_test, tst-epoll, tst-poll, tst-async, tst-fork-irq-cow all pass with OSV_RX_INLINE unset AND =64. New tiny tst-rx-napi-wake (assert-based).
Metal gate (DECISIVE): boot fork/PG image smp16 ramfs real tap stock PG.
  Control: OSV_RX_INLINE unset -> baseline 23,645 TPS at c64 (measured).
  Test: OSV_RX_INLINE=64. pgbench -S at c64 AND c128 + c32 RW sanity.
  PASS = c64+c128 complete, 0 deadlock, 0 assert, TPS >= control (regression >2% = fail).
  gdb liveness: >=1 runnable thread (failure signature was all-vCPU do_idle).

## Kill criteria
- Still deadlocks after moving all net_channel work to poll thread -> lost-wakeup is in wait_object<net_channel> arm/disarm vs wake_impl CAS, not the ISR nesting; bottom-half moot.
- TPS not >= 23,645 control -> receiver hop wasn't the bottleneck; HOP5 backend-wake IPI dominates; correct lever is RSS-steer backend wake onto rx CPU (Option B), not a bottom-half. Ship only if TPS-neutral-or-better AND deadlock-free.
- wake_with_irq_disabled trips !is_app() assert -> driver-init bug (poll thread flagged is_app()).
Fallback: whole feature behind OSV_RX_INLINE default 0 = byte-identical; nothing regresses.

## Critical files
drivers/virtio-net.cc (binding lambda :423-448, receiver :623, rx_drain :657, rx_inline_weight :88)
drivers/virtio-net.hh (rxq struct: deferred SPSC, poll_task, rxq_stats.rx_bh_wakeups)
core/net_channel.cc (post_packet/wake/wake_pollers + is_app asserts + NET_SHARED_KH)
include/osv/net_channel.hh (net_channel::wake :52, wait_object arm/disarm/poll :66-76)
core/sched.cc (wake_impl :1588, wake_from_kernel_or_with_irq_disabled :2078, CAS-drop)
