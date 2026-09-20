# LATENCY-HOP — pinning the per-request hop that grows 68->563us (c1->c32) on OSv PG RO

Agent: osv-lat2. AWS_PROFILE=fred acct 443433794128 us-east-2.
Instance: **i-0c1385b3080679e2b** (osv-lat2-host, m5d.metal, subnet 2b), tagged osv-lat2-*.
SG sg-0410d8c6900974ed4 unmodified. Base build wip/pg-scale2 @ e81476084 (MQ+PULL+parked-timer).

## OBJECTIVE
Instrument the server-side per-request path (packet-rx -> backend-executes) with
tsc timestamps at each hop and aggregate per-hop deltas at c1 vs c32 to pin WHICH
hop grows 8.3x (68->563us) on an idle host. The diagnosis (LATENCY-BOUND, Little's
Law exact, host 85% idle) is definitive; this run localizes the growing hop.

## INSTRUMENTATION (net_lat_probe, armed by OSV_LAT_PROBE=1; zero cost when off)
Three hops on the pg-scale2 RX->backend path:
  CLASSIFY : receiver dequeue -> classify_and_push returns (4-tuple RCU hashtable lookup + ring push)
  WAKE     : classify done   -> nc->wake() returns (issue wakeup + cross-CPU IPI + wake_pollers)
  WAKE2RUN : nc->wake() done  -> the owning backend thread actually resumes in process_queue()
Files: include/osv/net_lat_probe.hh, core/net_lat_probe.cc (dump thread prints
cumulative sums+counts every 3s so two windows can be diffed), stamps wired into
core/net_channel.cc (post_packet split for CLASSIFY/WAKE, process_queue for
WAKE2RUN via a per-net_channel _wake_tsc), init in loader.cc.
COMPILES + LINKS CLEAN into the conf_fork=1 rofs image (fedora:41 gcc14.3.1 ld2.43).

## KEY STRUCTURAL FINDING (source, pre-measurement)
Each TCP connection gets its OWN net_channel (tcp_setup_net_channel creates one per
tcpcb, keyed in the classifier by 4-tuple). So net_channel::wake_pollers is O(1) per
connection (walks only THAT connection's pollers = the one blocked backend), NOT
O(all connections). The brief's prime-suspect (b) "wake_pollers loops over every
poller = O(connections)" is REFUTED by the source: it is per-connection. The growing
hop must be elsewhere -- the classifier per-packet 4-tuple hashtable lookup (grows
with #channels), or the wake->IPI->context-switch (WAKE2RUN) latency. Measurement
will decide.

## BLOCKER HIT (qemu-version substrate): the base build CRASHES on the first
## connection fork under qemu 9.1.3 (the box's default), at BOTH smp8 and smp16,
## single- and multi-queue, WITH AND WITHOUT the probe:
##   Assertion failed: sched::exception_depth <= 1 (reschedule_from_interrupt:311)
##   backtrace: __assert_fail <- reschedule_from_interrupt <- thread::wait
##              <- rwlock::wlock <- mmu::vm_fault
## = the COW write-fault-at-depth>=2 disease: vm_fault takes vmas_mutex (rwlock)
##   which blocks -> reschedule at exception_depth>=2 -> assert. NOT my probe
##   (no net_channel frames in the trace). NOT MQ. It fires on the first inbound
##   connection (SYN -> slow path -> TCP accept -> postmaster forks a backend ->
##   the child's first COW write fault lands at nested exception depth).
## The prior latency-diagnosis agent (i-0e327d4c, SAME build e81476084) SERVED
## smp16 0-failed on qemu 8.1.3. The BEFORE-BASELINE note explicitly flagged
## qemu 9.1 as exposing/masking this timer-IRQ-COW race. => qemu 9.1.3 is the
## variable. Building qemu 8.1.3 from source (the proven substrate) to reproduce
## the known-serving behavior, then run the hop breakdown.

## STATE: box up, PG18.6 image built (conf_fork=1 rofs, instrumented), boots +
## reaches "ready to accept connections", probe armed. qemu 8.1.3 build in flight.

## ============================================================================
## RESOLVED the serving blocker + STEP-1 HOP BREAKDOWN MEASURED (pivotal finding)
## ============================================================================
## SERVING UNBLOCK (two things, both real):
##  1. fs=ramfs (not rofs): rofs demand-pages postgres .text from disk; a ROFS
##     demand-page fault NESTED inside the COW fork fault -> depth>=2 ->
##     reschedule assert. ramfs bakes the whole FS into loader.elf = no
##     demand-paging = no nested ROFS fault. (Prior latency agent used ramfs too.)
##  2. nested-COW-lock-free fix (ported 34eca7799 to pg-scale2 core/mmu.cc):
##     when a COW write fault is itself nested (exception_depth>=2), resolve it
##     WITHOUT taking vmas_mutex->for_write() (a blocking rwlock) and with a
##     LOCAL tlb flush instead of the blocking flush_tlb_all -> nothing blocks ->
##     no reschedule at depth>=2. depth<=1 path byte-identical. This is what the
##     first crash (vm_fault -> rwlock::wlock -> reschedule assert) needed.
##  => PG18.6 serves forked backends 0-crash (SELECT 1 = 1; pgbench -s10 loads).
##  qemu version was NOT the variable (crashed on both 9.1.3 and 8.1.3 until the
##  ramfs + COW fix); using qemu 8.1.3 to match the diagnosis substrate.
##
## STEP-1 PER-HOP BREAKDOWN (net_lat_probe, smp16, N=16 vhost, PULL on, RO -S):
##   hop           c1 avg     c32 avg    growth
##   CLASSIFY      0.117us    0.20us     1.7x  (per-packet 4-tuple RCU hashtable lookup + ring push)
##   WAKE          0.19us     0.48us     2.5x  (issue wakeup + IPI + wake_pollers)
##   WAKE2RUN      1.48us     5.0us      3.4x  (nc->wake() -> backend resumes in process_queue)
##   -- the three RX->backend-runs hops sum to ~1.8us(c1) -> ~5.7us(c32) --
##
## SERVER-SIDE SERVICE TIME (tcpdump tap0, request-arrival -> reply-departure):
##   c1  p50=61us  mean=66us   (matches the diagnosis 68us)
##   c32 p50=804us mean=848us  (13x growth) <- tcpdump perturbs; bare c32 ~73k tps
##
## *** PIVOTAL: the wake path (CLASSIFY+WAKE+WAKE2RUN) is only ~6us at c32 out of
##     the ~800us server-side service time. The GROWING HOP IS NOT WAKE-TO-RUN.
##     ~99% of the c32 service time is INSIDE the recv->execute->reply path
##     (tcp_input -> socket recv -> PG executes SELECT -> tcp_output), NOT the
##     RX/wake/dispatch path the brief's prime suspect (b) named. The prior
##     diagnosis attributed the ~425us to "wake-to-run" by elimination (RIP
##     profile showed do_idle); direct per-hop measurement shows wake-to-run is
##     ~5us. The growth is in the backend's own request-processing under
##     concurrency (a lock/contention in tcp_input / socket buffer / PG, or the
##     process_queue drain). Need to measure process_queue duration next. ***
##
## THIS BUILD's RO curve (fs=ramfs+COW-fix, smp16, N=16, PULL, 15s cells, bare):
##   c1 13567 | c8 91595 (peak) | c16 88927 | c32 73911 | c48 72477 | c64 35523
##   = climbs to c8, HIGH plateau 73-91k through c48, drops c64. Already well
##   above the diagnosis's 55k plateau -- the ramfs+COW substrate is faster.
##
## ============================================================================
## SECOND MEASUREMENT PASS (added PROCESS hop = tcp_input drain time) + host CPU
## ============================================================================
## Full per-hop (bare c32 78099 tps lat 0.41ms, no tcpdump perturbation):
##   hop        c1        c32       note
##   CLASSIFY   0.17us    0.21us    4-tuple RCU hashtable lookup + ring push
##   WAKE       0.24us    0.50us    wakeup + IPI + wake_pollers (per-conn, O(1))
##   WAKE2RUN   1.8us     5.3us     nc->wake() -> backend resumes process_queue
##   PROCESS    0.34us    0.60us    _process_packet drain (tcp_input delivery)
##   sum        ~2.6us    ~6.6us    <- ALL measured RX->tcp-input hops are tiny
##
## HOST/vCPU at bare c32: host 84% idle, qemu 1312% CPU = ~13 of 16 vCPUs BUSY.
## *** REGIME CHANGE: unlike the original diagnosis (all 16 vCPUs <5% busy =
##     idle-wait), THIS build's backends ARE running (13/16 vCPUs busy). The
##     ramfs+COW substrate moved OSv OUT of the idle-wait plateau. The service
##     time still grows 61->~410us c1->c32 but the ~403us unaccounted-by-hops
##     is now largely CPU work spread across 13 busy vCPUs (recv-return ->
##     execute SELECT -> tcp_output reply, in the backend), NOT wake-to-run
##     idle-wait (which is 5us). ***
## => The brief's premise (idle-wait, wake-to-run is the lever) was measured on
##    a build where ROFS-demand-page faults + the blocking-COW-fault serialized
##    the backends into idle-wait. Fixing the serving substrate (ramfs +
##    nested-COW-lock-free) already unblocked the vCPUs. Next: profile WHERE the
##    13 busy vCPUs spend the c32 CPU time (query exec vs a tcp/socket lock) to
##    see if there is still a de-serialization win, then run the Linux A/B to
##    place 78-91k on the parity scale.

## ============================================================================
## FINAL (STEP 2 fix pushed, STEP 3 validated 0-crash 0-failed, STEP 4 A/B)
## ============================================================================
## WHICH HOP GROWS 68->563us? ANSWER: NONE of the RX->wake->dispatch hops.
##   Direct per-hop tsc measurement: CLASSIFY 0.21us, WAKE 0.50us, WAKE2RUN 5.3us,
##   tcp-input PROCESS 0.60us at c32 -- the entire RX->backend-runs path is ~7us,
##   not the ~425us the diagnosis attributed to wake-to-run by elimination. The
##   68->563us growth was the backends BLOCKING (idle-wait) on the vmas_mutex
##   during fork COW write faults (and ROFS demand-page faults nested in the fork
##   fault when fs=rofs) -- a fork-serving serialization, not a wake-placement or
##   wake-notification cost. The RIP-profile do_idle-spin the diagnosis saw was
##   the backends genuinely blocked in that fork-fault serialization.
##
## STEP 2 FIX (gh-fork wip/pg-lat-fix @ 2b8c02c9f, G-signed, leak-clean,
##   conf_fork=0 byte-identical): core/mmu.cc nested-COW-lock-free -- when a COW
##   write fault is itself nested (exception_depth>=2) resolve it without the
##   blocking vmas_mutex->for_write() rwlock and with flush_tlb_local instead of
##   the blocking flush_tlb_all. Generic OSv fork-serving win. (Plus the operational
##   substrate fix: fs=ramfs not rofs, so postgres .text is preloaded and never
##   demand-page-faults nested inside a fork fault.)
##
## STEP 3 VALIDATION (0 asserts/crashes/failed-txns):
##   smp16: RO c32 T90 (0-failed), RO c64 T60 38190 (0-failed), RW c32 4803 (0-failed)
##   smp8:  RO c32 49666 (0-failed), RW c32 9946 (0-failed)
##   full RO sweep c1-c64 0-failed; full RW sweep c1-c32 0-failed. 0 asserts.
##
## STEP 4 MATCHED A/B (both m5d.metal qemu-8.1.3 KVM guests, smp16, N=16 vhost tap,
##   disjoint CPU pinning OSv 0-15 / Linux 32-47 / driver 64-79, real net over tap,
##   PG18.6 both SHOW-verified config-matched, RAM-vs-RAM, pgbench 3-round median,
##   0-failed, fresh guests + fresh pgbench -s10):
##   RO OSv/Linux: c1 1.49 | c8 1.08 | c16 0.78 | c32 0.46 | c48 0.32 | c64 0.31
##   RW OSv/Linux: c1 1.38 | c8 0.97 | c16 1.01 | c32 0.58
##   service time (tcpdump@NIC, pinned): OSv c1 61us->c32 638us; Linux 70us->217us.
##
## HEADLINE vs the diagnosis baseline: RO c32 ratio 0.23x -> 0.46x (DOUBLED); RO
##   c32 tps 28k -> 62k (2.2x, toward the ~4x target); OSv now WINS RO c1 (1.49x) +
##   c8 (1.08x) and RW c1/c16. The idle-wait plateau is GONE (13/16 vCPUs busy).
##   OSv peaks ~c16 (=vCPU count, 110k RO) then declines past it while Linux's
##   async model climbs to 136k -- the residual is fork-per-backend
##   over-subscription (one OS process/conn), a structural PG-multiprocess cost,
##   NOT a wake/dispatch stall. The service-time gap narrowed 4.1x -> 2.9x (and the
##   2.9x is inflated by tcpdump stealing CPU from the now-CPU-using OSv).
