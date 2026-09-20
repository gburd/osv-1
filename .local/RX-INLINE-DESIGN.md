# RX-INLINE-DESIGN (agent osv-rxinline) - collapse the per-request RX->backend wake hops

Goal: cut the per-request receiver-thread -> backend-thread wake hop, the wake-bound floor
(ZFS-READPATH.md: 49.7% do_idle + 26.8% handle_incoming_wakeups = 76.5%; ~4.3 ctx-sw/query).
Base: gh-fork wip/pg-tail-fix @ 79ed402f4. Build conf_fork=1 fs=ramfs, smp16, real net.

============================================================================
## STEP 1a - THE EXACT CURRENT HOP SEQUENCE (per RX packet -> PG backend runs)
============================================================================
Traced through the actual source (drivers/virtio-net.cc, arch/x64/exceptions.cc,
core/net_channel.cc, core/sched.cc). Thread / context / AS / preemption state of each hop:

  HOP 0  NIC posts RX buf -> MSI-X vector fires.
         CTX: hardware. 

  HOP 1  x64 `interrupt(frame)` (exceptions.cc:257) -> idt.invoke_interrupt(vector).
         CTX: IRQ context, irq DISABLED, on WHATEVER cpu the MSI-X vector is routed to
              (virtio-net routes rx[i] vector -> the poll thread's cpu; single-queue = cpu0).
         Runs the registered handler chain under rcu_read_lock:
           pre_eoi (the "isr"/high-prio) = rxq->vqueue->disable_interrupts()  [PCI MSI-X path,
                    virtio-net.cc:396] or ack_irq() [legacy pci_interrupt, :413].
           eoi().
           post_eoi = _rxqs[0]->poll_task->wake_with_irq_disabled()  [virtio-net.cc:414 legacy,
                    or the MSI-X binding's `poll` thread wake].
         *** So the IRQ handler does NOT drain the ring. It only disables the queue's
             interrupts + WAKES the poll_task. This IS the collapsible receiver-thread hop. ***
         !preemptable() here (IRQ ctx). AS = AS0 (kernel).

  HOP 2  wake_with_irq_disabled -> wake_impl (sched.cc:1588). poll_task is PINNED to the rx cpu
         (virtio-net.cc:379, single-queue = cpu0). Since the IRQ ran on that same cpu,
         tcpu == current() -> NO IPI, just need_reschedule=true (the cheap same-cpu case).
         => the poll_task wake is already IPI-free on the single-queue path (rx irq + poll_task
            co-located on cpu0). The receiver-thread hop is a CONTEXT SWITCH on cpu0
            (idle/other -> poll_task), not an IPI. Still a scheduling hop + a thread it need not be.

  HOP 3  poll_task (thread "virtio-net-rx", priority_infinity, pinned rx cpu) runs receiver()
         (virtio-net.cc:623). wait_for_queue returns (used_ring_not_empty). Drains the rxq:
         get_buf_elem loop -> packet_to_mbuf -> per packet:
             fast = _ifn->if_classifier.post_packet(m_head)   [virtio-net.cc:703]
             if (!fast) (*_ifn->if_input)(_ifn, m_head)         [:705]
         CTX: kernel thread, PREEMPTION EFFECTIVELY DISABLED for the classify path
              (net_channel asserts !is_app(); NET_SHARED_KH forces identity-heap), AS0.
         BOUNDED: drains only what is in the ring (a NAPI-like natural budget = ring depth),
              refills as it goes. Not unbounded.

  HOP 4  classifier::post_packet (net_channel.cc:157) under rcu_read_lock:
             classify_ipv4_tcp(m)  -> finds the owning socket's net_channel by 4-tuple.
             nc->push(m)           -> lock-free enqueue onto the socket's net_channel queue.
             nc->wake()            -> net_channel::wake_pollers (net_channel.cc:51):
                 for each pollreq: pr->_awake=true; pr->_poll_thread.
                                   wake_from_kernel_or_with_irq_disabled()   <- WAKE THE BACKEND
         *** tcp_input itself is deferred: net_channel's _process_packet runs tcp_input when the
             backend drains its queue (process_queue), NOT in the receiver. So the receiver does
             classify + enqueue + wake; the backend does tcp_input + socket-deliver + app read.
             (net_channel is the "widen tcp_input inline" lever - option C-tcp below.) ***

  HOP 5  wake_from_kernel_or_with_irq_disabled -> wake_impl for the BACKEND thread.
         The backend last ran on ITS cpu (say cpuB), which after replying went to do_idle.
         tcpu(backend)=cpuB, current cpu = the rx cpu (cpu0). cpuB != cpu0 (backends are NOT
         pinned to cpu0; the scheduler + WAKE_PULL spread them) -> **send_wakeup_ipi() to cpuB**
         (sched.cc:1612). This is the cross-cpu IPI + VM-exit the profile pays.
         => THE FUNDAMENTAL WAKE. AS: the backend has its own fork AS; but wake_impl only
            touches the shared detached_state + the target cpu's incoming_wakeups (identity heap),
            so the wake itself is AS-safe. Running the backend's query is in ITS AS, on cpuB.

  HOP 6  cpuB was in do_idle (or idle-spinning per OSV_IDLE_SPIN). IPI arrives -> exits the spin
         -> schedule() -> context-switch INTO the backend. Backend returns from recv(), runs
         net_channel process_queue (tcp_input) + the socket read, executes the query, writes the
         reply (TX), blocks again in recv() -> cpuB back to do_idle.

### HOP SUMMARY (single-queue, the benchmarked config)
  IRQ(cpu0) --wake--> poll_task(cpu0, ctx-switch, no IPI) --classify+wake--> backend(cpuB, IPI+
  ctx-switch) --query+reply--> sleep.
Per request: 1 IRQ, 1 same-cpu ctx-switch (poll_task), 1 cross-cpu IPI + 1 ctx-switch (backend),
1 TX. Matches the measured ~4.3 ctx-sw/query and ~6.3 VM-exits/query (rx-irq + wake-IPI + io-kick
notify + tx + halt/idle exits).

============================================================================
## STEP 1b - WHICH HOPS COLLAPSE, WHICH ARE FUNDAMENTAL
============================================================================

FUNDAMENTAL (cannot vanish for a blocking-recv process-per-connection PG):
  - HOP 5 (wake the backend) + HOP 6 (ctx-switch into it). The PG backend is a blocked app
    thread in its OWN address space; its query MUST run in that AS on a cpu. It cannot run
    inline in the IRQ/receiver (foreign AS + !preemptable() -> the fork-arena page-fault crash
    the CONF_fork NET_SHARED_KH note warns about). So ONE backend wake per request is the floor,
    exactly the WAKE-INLINE-RESULT.md verdict. Linux pays this too (softirq wakes the socket
    owner); Linux's edge is it does HOPs 1-4 INLINE in the softirq with NO separate receiver
    thread hop and often wakes the owner on the SAME cpu (no IPI).

COLLAPSIBLE:
  - HOP 1->2->3 (the receiver-THREAD hop). The IRQ handler currently only disables the queue
    and wakes a SEPARATE pinned thread (poll_task) to drain+classify. That thread hop is a
    context switch that Linux's NAPI does NOT have (NAPI drains + delivers in the softirq that
    the IRQ raised). We can drain+classify DIRECTLY in a bounded budget IN THE IRQ/poll context
    and skip waking the receiver thread when the ring is shallow. => OPTION A.
  - HOP 5's IPI (not the wake itself). If the backend can be made to (re)run on the SAME cpu as
    the rx irq, wake_impl takes the need_reschedule path (no send_wakeup_ipi). => OPTION B.
  - tcp_input placement (widen inline). net_channel already defers tcp_input to the backend's
    process_queue. Doing tcp_input in the receiver would hand the backend a fully-ready socket
    (wake carries a ready read), shaving backend work per wake, but ADDS work to the
    !preemptable() receiver context (risk) and does not remove a hop. => OPTION C, deferred.

============================================================================
## STEP 1c - THE CONCRETE INLINE-DELIVERY DESIGN (safe, bounded, NAPI-like)
============================================================================

### OPTION A (chosen for the prototype) - drain+classify IN THE RX-IRQ/poll context, NAPI-style
Instead of "IRQ disables queue + wakes poll_task; poll_task drains", do a BOUNDED drain right in
the wake path so the common shallow-ring case never schedules the separate receiver thread.

SAFEST FORM that respects !preemptable()/AS0 (does NOT touch the IRQ top-half, which is the most
delicate): keep the existing poll_task, but have the RX MSI-X handler, instead of unconditionally
waking the poll_task, do a BOUNDED inline drain of up to W packets (NAPI "weight") right there in
the post_eoi/isr context (already IRQ ctx, irq-disabled, AS0, !preemptable - the SAME safety
envelope the classifier already runs under). For each drained packet call
_ifn->if_classifier.post_packet (the existing net_channel classify+enqueue+wake-backend, proven
safe in !preemptable AS0). Only if the ring still has buffers after W (a burst) fall back to
waking the poll_task to finish the drain (bounded work per IRQ, no starvation, matches NAPI's
budget-then-reschedule). This COLLAPSES HOP 1->2->3 into HOP 1 for the common case: IRQ ->
classify -> wake backend, no receiver-thread context switch.

Why this is the safe high-value piece:
  - post_packet already runs in exactly this context today (the poll_task is also !preemptable
    for the classify), so calling it from the IRQ handler adds NO new AS/preemption hazard - it
    is the SAME code in a context with the same guarantees. The dangerous thing (running app/
    backend/foreign-AS work inline) is NOT done: we only classify+enqueue+wake, never run
    tcp_input-into-app or the backend.
  - Bounded by W (weight) -> cannot monopolize the cpu in the IRQ handler; a burst reschedules
    the poll_task exactly as today.
  - The mbuf allocations in packet_to_mbuf use the identity heap (rx buffers), AS-safe.
  - Fallback to if_input (non-TCP / unclassified) still needs the poll_task (if_input walks the
    generic stack which may not be IRQ-safe) -> if a packet does NOT classify, wake the poll_task
    and let it handle the rest (do NOT call if_input inline). So inline only the net_channel
    fast path; punt everything else to the thread. Safe by construction.

RISK: the drain touches vring get_buf/finalize/fill_rx_ring in IRQ ctx. These already run in the
poll_task with irq effects; must confirm they are safe with irq fully disabled (they are ring
memory ops + an occasional kick). Bound the refill. Keep W small (e.g. 16-64).

### OPTION B (co-locate the backend wake on the rx cpu - kill HOP 5's IPI)
On a single rx queue, all classify+wake happens on cpu0. The backend runs on cpuB != cpu0 ->
IPI. If we STEER the backend's wake to cpu0 (or bias its scheduling to the rx cpu), wake_impl
takes the same-cpu need_reschedule path (no IPI, no cross-cpu VM-exit). But: co-locating all
backends on cpu0 serializes them (defeats smp). The right form is Linux-RPS-like: spread rx
across cpus (MULTIQUEUE, already partially in the driver) so each backend's rx irq lands on ITS
cpu. That is a bigger change (MQ + RSS steering by 4-tuple to the backend's cpu). DEFER;
note it as the IPI-removal follow-on. Option A alone removes the receiver-thread hop, which is
the cheaper, safer win and is orthogonal to B.

### OPTION C (widen tcp_input inline / batch wakes) - DEFER
net_channel already classifies inline; moving tcp_input into the receiver adds !preemptable work
for no hop removal. Batching wakes (the "FIXME: find a way to batch wakes" at net_channel.cc:164)
could coalesce multiple backends' wakes per IRQ but PG is one-socket-per-backend (each packet
wakes a different backend) so batching wakes helps little for PG. DEFER.

### vs LINUX NAPI
Linux: IRQ raises softirq -> net_rx_action polls the driver (budget=weight=64) IN THE SOFTIRQ,
runs the full receive (GRO, ip_rcv, tcp_v4_rcv) and delivers to the socket, waking the owner -
all in one softirq context, no separate "receiver thread" hop, and the owner is often woken on
the same cpu (no IPI, RPS/RFS steer to the app's cpu). OPTION A makes OSv's IRQ path do the
bounded drain+classify+enqueue+wake inline (the NAPI-poll-in-softirq analog); OPTION B is the
RPS/RFS analog (wake the owner on the rx cpu). A closes the receiver-thread hop; B closes the
IPI. The backend wake itself (HOP 5/6) is the shared floor both pay.

============================================================================
## STEP 2 PLAN - the safe bounded prototype = OPTION A, env-gated, off-by-default
============================================================================
Env: OSV_RX_INLINE=<weight> (0 = OFF = byte-identical existing behavior; wake poll_task always).
Change site: the RX MSI-X post_eoi handler (and the legacy pci_interrupt) in virtio-net.cc.
Add a net::rx_inline_drain(rxq, weight) that, in the IRQ ctx:
  - drains up to `weight` used bufs, builds mbufs, calls if_classifier.post_packet per packet;
  - for any packet that does NOT classify (fast_path==false), stop inlining and wake poll_task
    to handle the remainder (safe: generic if_input only in the thread);
  - if the ring still has bufs after `weight`, wake poll_task to finish (NAPI reschedule);
  - refill the rx ring as it drains (bounded).
Guard everything on the env weight != 0. Unset -> the handler is the original single
poll_task->wake_with_irq_disabled() line, byte-identical.

VALIDATION GATES (STEP 3): !preemptable() assert (the fork-arena crash), missed-wake hang
(a packet drained inline but its backend not woken -> PG stall), dropped/reordered packet
(net_channel push ordering). Test: fork -i -s50 x3, real PG serve, RO c8/c16/c32 + RW c32 smp16,
0 asserts/crashes/failed/hangs, A/B OSV_RX_INLINE on vs off vs Linux, RIP-resample (did
do_idle+handle_incoming_wakeups drop from 76%?), KVM ctx-switch/query (from ~4.3).

============================================================================
## STEP 3 FINDING - the !preemptable() crash (the fundamental blocker for A)
============================================================================
The Option-A prototype (drain+classify inline in the RX MSI-X handler) BUILDS
clean, BOOTS clean (OSV_RX_INLINE=64), and passed a light load (64 conns,
64/64 hash replies correct, 0 crash) AFTER fixing an initial missed-wake bug
(the poll thread's wait predicate did not account for the deferred ring, so a
deferred SYN's wake was slept through -> handshake never completed; fixed by
waiting on ring-not-empty OR deferred-not-empty).

BUT under a harder stress (128 threads x 20 rounds, payloads up to 64KB,
sustained), it hit exactly the crash the brief warned about:

  Assertion failed: sched::preemptable() (arch/x64/mmu.cc: page_fault: 38)
  0x...page_fault
  0x...malloc
  0x...uma_zalloc_arg
  0x...virtio::net::packet_to_mbuf+61
  0x...virtio::net::rx_drain+487
  0x...(the RX MSI-X isr lambda)
  0x...interrupt_descriptor_table::invoke_interrupt
  0x...interrupt
  0x...sched::cpu::idle    <- IRQ fired while the cpu was idle

ROOT CAUSE (decisive): the RX drain BUILDS mbufs (packet_to_mbuf -> m_gethdr ->
uma_zalloc_arg -> malloc). malloc can PAGE-FAULT (heap growth / a lazily-mapped
page). A page fault requires preemption to service; the RX MSI-X handler runs
with preemption DISABLED (IRQ context), so the fault trips
assert(sched::preemptable()) in page_fault. This is NOT the fork-arena
foreign-AS hazard and NOT the classifier - it is the mbuf ALLOCATOR. The poll
thread never hits this because it runs preemptable; the IRQ handler cannot.

=> FUNDAMENTAL CONSTRAINT: you cannot build mbufs (allocate) in the raw IRQ
   handler. OSv has no softirq/NAPI-poll context (a preemptable bottom half
   that may allocate) - the receiver poll THREAD *is* that context. So the
   "drain+classify fully inline in the IRQ handler" form of Option A is unsafe
   as written: the packet cannot be classified without first building the mbuf,
   and building the mbuf can fault.

### SALVAGE PATHS (for the next iteration)
 (1) Pre-allocated mbuf-header pool per rxq, refilled by the poll thread, so
     the IRQ path pops a ready header (no malloc, no fault). rx buffers are
     already pre-posted; the mbuf *struct* is the only allocation. This makes
     the inline drain fault-free. Medium complexity, the right NAPI-analog fix.
 (2) Option B instead (co-locate the backend wake on the rx cpu to drop the
     IPI) - does not touch the alloc path at all, orthogonal, likely safer.
 (3) Reserve/pre-touch the mbuf zone so uma_zalloc never grows the heap in the
     IRQ path (fragile - a burst still grows it).
 (4) Keep the poll-thread hop but have the IRQ handler do the CHEAP part
     (nothing that allocates) - i.e. there is no cheap part that helps, because
     classify needs the mbuf.

### HONEST VERDICT ON STEP 2/3
The receiver-thread hop is REAL and collapsible in principle (Linux NAPI does
exactly this), but OSv's mbuf allocator is not IRQ-safe, so the naive inline
drain crashes under load. The safe version needs a pre-allocated header pool
(salvage 1) or a different lever (Option B). The prototype + this crash are
banked; the off-by-default gate keeps it byte-identical so nothing regresses.
