# RX-INLINE-RESULT (agent osv-rxinline) - the inline-RX lever: design + prototype + verdict

Instance: m5d.metal us-east-2 (osv-rxinline-host, self-terminated). AWS_PROFILE=fred acct ...128.
Base: gh-fork wip/pg-tail-fix @ 79ed402f4. Build conf_fork=1 fs=ramfs, fedora:41 container, KVM.
Branch pushed: gh-fork **wip/pg-rx-inline @ b318d8502** (G-signed, leak-clean, OFF-by-default
byte-identical). Design banked .local/RX-INLINE-DESIGN.md (the hop-map + full design).

## THE GOAL
Cut the per-request receiver-thread -> backend-thread wake hop (the wake-bound floor: 49.7%
do_idle + 26.8% handle_incoming_wakeups = 76.5%, ~4.3 ctx-sw/query). Make OSv RX more inline/
softirq-like (Linux NAPI: drain+deliver in the softirq the IRQ raised, no separate receiver
thread hop, wake the owner often on the same cpu).

## STEP 1 - HOP MAP + DESIGN (banked in full in RX-INLINE-DESIGN.md)
The exact per-packet path (single-queue, the benchmarked config):
  IRQ(rx cpu) --wake poll_task(same cpu, ctx-switch, NO ipi)--> receiver drains+classifies
  --net_channel post_packet: classify + enqueue + wake owning backend(cpuB != rx cpu, IPI+
  ctx-switch)--> backend runs tcp_input + query + reply --> sleeps.
FUNDAMENTAL (cannot vanish for blocking-recv PG): the backend wake+ctx-switch (HOP 5/6) - the
  backend is a blocked app thread in its own AS, its query must run there. Linux pays this too.
COLLAPSIBLE: the receiver-THREAD hop (IRQ -> wake a separate poll_task -> that thread drains).
  Linux NAPI has no such hop. Option A = drain+classify directly in the RX IRQ handler, bounded
  by a NAPI weight; only the net_channel fast path inline (never generic if_input), defer control
  packets + overflow to the poll thread.
Also documented: Option B (co-locate backend wake on rx cpu to drop the IPI - the RPS/RFS analog,
  deferred), Option C (widen tcp_input inline - deferred, no hop removal for PG).

## STEP 2 - PROTOTYPE (Option A, OSV_RX_INLINE=<weight>, off-by-default, #env-gated)
net::rx_drain(rxq, budget, inline_ctx) factored out of receiver() (poll thread = unbounded,
inline path = bounded budget in the RX MSI-X isr). Inline path delivers established-TCP packets
via net_channel post_packet; classify misses (ARP/ICMP/SYN) deferred to the poll thread via a
per-rxq SPSC lock-free ring (ring_spsc<mbuf*,unsigned,256>) drained by receiver() via if_input;
poll thread woken only when the ring is not fully drained or a packet was deferred. Wake-loss
guarded: the poll thread waits on ring-not-empty OR deferred-not-empty; the isr re-enables the
queue interrupt + re-checks when it finishes without waking the thread. +~220 lines, whole driver
byte-identical when OSV_RX_INLINE unset (0/unset = original single poll_task->wake line).

## STEP 3 - VALIDATION (build/boot/light-load PASS; heavy-load CRASH, root-caused)
- BUILD: conf_fork=1 fs=ramfs compiles + LINKS clean (loader.elf, loader-stripped.elf).
- BOOT: OSV_RX_INLINE=64 boots clean, eth0 up, no assert. Byte-identical boot vs OSV_RX_INLINE=0.
- LIGHT LOAD (64 conns, 4KB each, TCP hash server = blocking-recv-per-connection PG analog):
  OSV_RX_INLINE=64 -> 64/64 correct hash replies, 0 fail, 0 crash. Baseline (0) -> 64/64.
  (First iteration had a MISSED-WAKE bug: the poll thread's wait predicate did not include the
   deferred ring, so a deferred SYN's wake was slept through -> handshake hung -> 0/64. FIXED by
   waiting on ring-OR-deferred; then 64/64. This is the exact missed-wake hang the brief named,
   found + fixed.)
- HEAVY LOAD (128 threads x 20 rounds, payloads up to 64KB, sustained): OSV_RX_INLINE=64 hit
    Assertion failed: sched::preemptable() (arch/x64/mmu.cc: page_fault: 38)
    ...page_fault <- malloc <- uma_zalloc_arg <- packet_to_mbuf+61 <- rx_drain+487 <-
    (RX MSI-X isr) <- invoke_interrupt <- interrupt <- sched::cpu::idle
  Baseline (OSV_RX_INLINE=0) survived the IDENTICAL stress: 2557/2560 ok, 3 timeout-noise, 0
  crash. => the crash is caused SPECIFICALLY by the inline path, not the load (decisive A/B).

## ROOT CAUSE (decisive, backtrace-pinned)
The inline drain BUILDS mbufs: packet_to_mbuf -> m_gethdr -> uma_zalloc_arg -> malloc. malloc
can PAGE-FAULT on heap growth (the mempool pool .alloc() at core/mempool.cc:2150 pulling a fresh
page). The RX MSI-X handler runs with PREEMPTION DISABLED (IRQ context); a page fault requires
preemption to service, so it trips assert(sched::preemptable()) in page_fault. The poll thread
never hits this because it runs preemptable (its faults are serviced normally). This is NOT the
fork-arena foreign-AS hazard (kernel_heap_scope would not help - it is raw heap growth) and NOT
the classifier - it is the mbuf ALLOCATOR in a non-preemptable context.

## THE IRREDUCIBLE CONSTRAINT (the honest verdict)
OSv has NO softirq / NAPI-poll bottom half - a preemptable context that may allocate. Linux
NAPI runs in softirq (may allocate, may be preempted), which is exactly why Linux can drain+build+
deliver inline. OSv's equivalent preemptable "may allocate" context IS the receiver poll thread -
the very hop we are trying to remove. So "drain+classify+build fully inline in the IRQ handler"
is unsafe as written: you cannot classify without first building the mbuf, and building the mbuf
can fault while !preemptable.

=> HOW MUCH CLOSED vs IRREDUCIBLE:
   - The receiver-thread hop IS collapsible in principle (the design + prototype prove the
     mechanism: classify + net_channel wake work inline; the missed-wake + interrupt re-arm are
     solved).
   - What blocks the SAFE version is the ALLOCATION, not the scheduling. It is NOT irreducible -
     it needs a per-rxq PRE-ALLOCATED mbuf-header pool refilled by the poll thread (preemptable),
     so the IRQ path pops a ready header and NEVER allocates. That is the NAPI analog and the
     correct completion. It is a real refactor of the mbuf build/free path (the rx-buffer refcnt
     trick + m_extadd + the free callback must return the struct to the pool) - delicate net-stack
     surgery not finished this run under the burner clock.
   - The backend wake itself (HOP 5/6) remains the process-per-connection floor (WAKE-INLINE-
     RESULT.md): even a perfect inline receive still cross-cpu-wakes the blocked backend. Option B
     (co-locate the wake on the rx cpu) could drop the IPI but not the wake.

## STEP 4 - A/B THROUGHPUT: N/A (the inline path crashes under sustained load)
No throughput A/B or RIP-resample was run: OSV_RX_INLINE=on crashes under the sustained pgbench-
class load required for a meaningful measurement, so any tps/ctx-switch/do_idle% number would be
from a run that aborts. The correctness gate (no !preemptable crash, no missed-wake hang) is the
ship-gate per the brief, and it FAILS under load -> the feature is NOT shipped live (kept
off-by-default, byte-identical, marked EXPERIMENTAL in code + commit). The design's projected win
(remove the receiver-thread ctx-switch, ~1 of the ~4.3 ctx-sw/query) stands as a hypothesis the
pre-alloc-pool completion would let us measure.

## DELIVERABLES
1. .local/RX-INLINE-DESIGN.md - the full hop-map + inline-delivery design (the deep-lever
   roadmap: which hops collapse, which are fundamental, Options A/B/C, vs Linux NAPI). The
   highest-value artifact - stands on its own.
2. gh-fork wip/pg-rx-inline @ b318d8502 - the build/boot/light-load-verified Option-A prototype,
   OFF-by-default byte-identical, marked EXPERIMENTAL with the KNOWN LIMITATION (the alloc-in-IRQ
   fault) + the pre-alloc-pool completion path documented in the commit + this file.
3. This RESULT - the honest verdict: the receiver-thread hop is collapsible, the blocker is the
   non-IRQ-safe mbuf allocator (needs a pre-alloc pool, NOT irreducible), the backend wake is the
   remaining process-model floor. A/B decisive that the crash is the inline path, not the load.

## NEXT LEVER (precise, for whoever continues)
Implement the per-rxq pre-allocated mbuf-header pool (fill_rx_ring stashes a pre-built mbuf per
posted rx buffer; the free callback returns it to the pool; the IRQ drain pops instead of
m_gethdr). That makes the inline drain fault-free -> re-run STEP 3 heavy-load gate -> if 0-crash
0-hang, run the STEP 4 pgbench A/B + RIP-resample to measure whether removing the receiver-thread
ctx-switch moves ctx-sw/query (from ~4.3) + do_idle% (from ~50%) + RO c8/c16/c32. Alternatively
Option B (wake the backend on the rx cpu to drop the IPI) is orthogonal and does not touch alloc.
