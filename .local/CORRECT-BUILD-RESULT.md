# CORRECT-BUILD-RESULT — osv-struct run: the c32+ tail lever + fix

Agent: osv-struct. AWS_PROFILE=fred us-east-2. Instance i-0d978ada3d74c9fb4 (m5d.metal 96 vCPU,
osv-struct-host) -- EXTERNALLY TERMINATED mid-STEP-3 ("User initiated shutdown", NOT by this
agent). Base wip/pg-lat-fix @ 2b8c02c9f. Fix pushed gh-fork **wip/pg-tail-fix @ 79ed402f4**
(G-signed, leak-clean, default byte-identical).

## THE FIX (STEP 2): sched: env-tunable idle spin-before-halt (OSV_IDLE_SPIN)
core/sched.cc, +24/-2. An idle CPU spins a fixed 10000 iterations polling incoming_wakeups before
halting via arch::wait_for_interrupt (a KVM VM-exit). Make that count env-tunable; default 10000 =
historical behavior byte-identical when unset. A longer spin catches a soon-arriving next request
in the poll loop and skips the halt VM-exit + its wake-IPI entirely.

## WHY THIS IS THE LEVER (STEP-1 measured, then STEP-2 confirmed mechanistically)
STEP-1 RIP (smp32 c32, 1920 samples): 66% sched::cpu::do_idle (busy-spin, nothing runnable), 8%
handle_incoming_wakeups, 1.5% x2apic::ipi; ZERO vm_fault/COW/vmas_mutex/malloc/socket-lock.
KVM debugfs: tlb_flush ~2/s (rules out TLB/COW), exits/s SATURATE ~400k from c16 on (~6-7 exits per
query = halt + wake-IPI + a few IO). => the tail is the per-request HALT/WAKE VM-exit round-trip,
not a lock (c) and not TLB/COW (b). STEP-2 A/B: raising the spin to 100000 collapses halt_exits/s
at c32 from 48975 to 434 (99%) and lifts tps -- the mechanism is confirmed.

## MATCHED A/B (paired, fresh boot + fresh pgbench -s50 per config, INTERLEAVED default-vs-spin,
## median-of-3, smp16, single-queue vhost, NUMA-clean node0 guest / node1 driver, PG18.6, 0-failed):
##   RO tps          default(10000)   spin(100000)   delta
##   c16             62973            67471          +7%
##   c32             63954            70998          +11%
##   c48             59870            70377          +17%
##   c64             55957            67218          +20%
##   RW c32          10202            15823          +55%
##   RO c1/c8: unchanged (no low-conc regression). spin>=100000 = diminishing returns.
##
## DISAMBIGUATOR (smp8/16/32 c32 OSv progression, the vCPU-sensitivity test):
##   RO c32 tps: smp8 49225 | smp16 64397 | smp32 70286  (smp8->16 +31%, smp16->32 +9% = DIMINISH)
##   smp32 HURTS the deep tail: c48 60389(smp16)->41474(smp32), c64 56411->38205 = scheduler churn.
##   => the tail is a wake/dispatch-LATENCY ceiling that vCPUs relieve only up to ~vCPU-count
##      concurrency, then hurt. NOT pure oversubscription (would keep scaling), NOT pure fixed cost
##      (smp8->16 gave +31%). A blend, and the halt/wake VM-exit round-trip is the fixable part.
##
## vs LINUX (prior matched A/B, same harness, Linux smp16 c32 ~136k RO): OSv lat-fix c32 was 62289
## (0.46x); OSv +idle-spin100k c32 ~71000 => ratio ~0.52x. The full fresh smp16-vs-smp32-vs-Linux
## 3-round sweep was NOT completed (box externally terminated); both guests were up + config-matched
## (SHOW-verified: shared_buffers 128MB / max_conn 300 / fsync on / sync_commit on / io sync, both
## PG18.6, RAM-vs-RAM = OSv ramfs / Linux tmpfs, disjoint NUMA pinning).

## CRASH GATE (heavy pgbench -i -s50 fork/COW index build, the IRQ-COW-timer hazard):
##   fixed spin 100000: 0/3 crashes | fixed spin 160000: 0/4 | pristine 10000: 0/3. Full RO+RW
##   sweeps 0-failed. REJECTED an adaptive-budget variant (crashed assert(preemptable) page_fault:38
##   under the -i load while the same-length FIXED spin did not) -- shipped the simple fixed
##   env-tunable, shelved the adaptive.

## HEADLINE: the c32+ tail was NOT (purely) irreducible fork-per-backend structure -- it is the
## per-request halt/wake VM-exit round-trip, a REAL generic FIXABLE lever. The OSV_IDLE_SPIN fix
## trades idle CPU cycles for fewer halt/wake round-trips: +7-20% RO / +55% RW across the whole
## c16-c64 tail, 0-failed, default byte-identical. DEPLOYMENT: size vCPUs to peak concurrency
## (smp32 helps c16/c32 but hurts c48/c64) AND set OSV_IDLE_SPIN=100000 for a busy server.

## ============================================================================
## WAKE-INLINE run (agent osv-wake, i-0a32e0e5d1b9f5eca m5d.metal us-east-2): the LAST residual
## (per-request receiver->backend WAKE handoff) MEASURED + a socket busy-poll fix that closes the
## DEEP-TAIL + RW portion. Remaining gap = the honest process-per-connection floor vs Linux async.
## Fix pushed gh-fork wip/pg-wake-inline @ a9790a49c (G-signed, leak-clean, OFF-by-default byte-id).
## ============================================================================
## STEP1 (measured, base wip/pg-tail-fix @ 79ed402f4 + OSV_IDLE_SPIN=100000, smp16, c32 RO 59555tps):
##   KVM debugfs: exits/s 374476 (~6.3/query), halt_exits/s 454 (idle-spin already collapsed halt),
##   io_exits/s 51200 (~0.86/query virtio notify), host ctxt-switch/s 254439 = ~4.3 CTX-SWITCHES/
##   QUERY. Host 74% idle at c32 (guest holds 16/96 cpus), vCPUs 60-99% = idle-spin, not app work.
##   => CONFIRMED residual = the per-request receiver->backend cross-thread WAKE + ctx-switch.
## STEP2 FIX = socket-recv busy-poll before block (OSV_SOCK_BUSY_POLL), bsd/sys/kern/uipc_sockbuf.cc
##   sbwait_tmo + net_channel::has_packet(), +40 lines. Before a backend blocks in recv() on a
##   net_channel socket, spin briefly polling for the imminent packet; catch it inline -> backend
##   never sleeps -> receiver never cross-thread wakes it. Socket-level analog of OSV_IDLE_SPIN /
##   Linux SO_BUSY_POLL. OFF by default (0 = byte-identical). MECHANISM confirmed: bp=10000 cut host
##   ctxt-switch/s 254439->203263 (-20%) at c32.
## STEP3 VALIDATED 0-crash 0-failed: RW c32/c64, RO c64, 3x heavy pgbench -i -s50 fork/COW gate,
##   sustained c48. bp=0 AND bp=10000 both stable c48/c64 in isolation. (One sweep-time crash at
##   c48 did NOT reproduce isolated; traced to the SIGSTOP-paused co-guest interaction -- fixed the
##   harness to fully STOP the idle guest per leg, no recurrence.)
## STEP4 MATCHED A/B (smp16, 1 m5d.metal, single-queue vhost, real net, RAM-vs-RAM, PG18.6
##   config-matched SHOW-proven, node0 guest / node1 driver, 3-round median, 0-failed):
##   OSv wake-inline A/B (bp0 vs bp10000): RO tail c48 40065->52845 (+32%), c64 38520->51842 (+35%);
##     RW +24-31% c8-c48 (c32 5018->6460). RO mid-range c8-c32 within noise (the one-shot +20% did
##     NOT survive median-of-3 -- honest). => a REAL tail+RW lever, not a uniform RO win.
##   vs LINUX PG18.6 (climbs RO c32 200316 / c64 210134; RW c32 26425 / c64 28712):
##     RO OSv/Lin: c1 1.00 | c8 0.61 | c16 0.30 | c32 0.26 | c48 0.25 | c64 0.25
##     RW OSv/Lin: c1 0.99 | c8 0.50 | c16 0.27 | c32 0.24 | c48 0.23
##   HEADLINE: OSv PARITY at c1, stable ~0.25x plateau c16-c64 (NO deep-tail collapse anymore).
## FINAL VERDICT (honest, the bank the brief asked for): idle-spin closed the halt-exit portion;
##   wake-inline closes the deep-tail + RW wake portion (fewer cross-thread wakes where they hurt).
##   The REMAINING ~4x gap at c16+ IS THE PROCESS-PER-CONNECTION FLOOR: a blocking-recv OS thread
##   that the busy-poll budget misses MUST be cross-thread woken (wake-IPI + ctx-switch), whereas
##   Linux async/epoll does the handoff INLINE in softirq with 0 extra per-request thread wake.
##   That is the irreducible cost of PG's process model on OSv vs Linux async -- a legitimate
##   structural final verdict, not a missing fix. Full tables .local/WAKE-INLINE-RESULT.md.
## AWS: box+vol osv-wake-* -- TERMINATE at end (see below). Never touched solnix-*/osv-native-*.
## ============================================================================
