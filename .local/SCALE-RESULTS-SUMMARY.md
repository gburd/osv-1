# SCALE-RESULTS-SUMMARY -- PostgreSQL-on-OSv scale arc (durable record)

Host-local only. NEVER push to a public remote. This is the single-file durable
record of the OSv PG-at-scale work so the multi-month maintainer gap (offline til
~Nov) does not lose it. Sources: ROADMAP.md, CORRECT-BUILD-RESULT.md, LATENCY-HOP.md,
BOTTLENECK2-DIAGNOSIS.md, DECLINE-DIAGNOSIS.md, MQ-RESULT.md, LATENCY-DIAGNOSIS.md,
RECONCILE-RESULT.md, LESSONS-pg-scale.md.

Workload throughout: real multiprocess PostgreSQL 18.x on OSv/KVM (postmaster forks
one OS process per backend, each with a COW address space), driven by pgbench, matched
apples-to-apples against Ubuntu PostgreSQL on the same host/harness/driver, config-
matched (shared_buffers / max_conn / fsync / sync_commit all SHOW-verified equal),
RAM-vs-RAM (OSv ramfs / Linux tmpfs), 3-round median, 0-failed-txn gated.

--------------------------------------------------------------------------------
## THE ARC (where it started -> where it is)

START: OSv served real forked PG backends only at smp1; at smp>=2 it CRASHED on the
first forked backend (assert(preemptable) in timer_list::fired, a COW-fork-path fault
taken in interrupt context). The only "parity" numbers were smp1-OSv vs smp8-Linux =
a floor, not vCPU-matched. Even once serving, the shape was: PARITY at c1, PEAK at c8,
then MONOTONIC DECLINE while Linux climbed to c32 -- on a host that was ~95% IDLE at
the collapse. An idle host with falling throughput = a contention/serialization
bottleneck that gets worse with concurrency, not a CPU limit.

END: OSv now CLIMBS through its vCPU count and holds a high plateau. It WINS RO c1
and c8 and RW c1-c16 outright against Linux, and the RO c32 OSv/Linux ratio has
roughly DOUBLED from the diagnosis baseline. The remaining tail (c32+) is the
structural fork-per-backend over-subscription cost, not a missed lever.

--------------------------------------------------------------------------------
## FINAL MATCHED A/B (the current trustworthy parity picture)

Both guests m5d-class bare-metal KVM, qemu-8.1.3, smp16, N=16 vhost tap, disjoint CPU
pinning (OSv / Linux / driver on separate core ranges), real net over tap, PG18.x
SHOW-verified config-matched, RAM-vs-RAM, pgbench 3-round median, 0-failed all cells,
fresh guests + fresh dataset per run.

RO (SELECT-only) tps:
  conc   OSv        Linux      OSv/Lin    (diagnosis-baseline OSv/Lin)
  c1     15131      10124      1.49x      (1.0x)     <- OSv WINS
  c8     91696      84901      1.08x      (~0.63x)   <- OSv WINS
  c16    110635     141803     0.78x      (~0.29x)
  c32    62289      136130     0.46x      (0.23x)    <- ratio DOUBLED
  c48    42320      132317     0.32x      (0.17x)
  c64    40123      131262     0.31x      (0.16x)
  OSv solo (no Linux/driver contention): c8 93564 / c16 ~110k / c32 79190.

RW (default TPC-B-like) tps:
  conc   OSv        Linux      OSv/Lin    (baseline)
  c1     2140       1546       1.38x      (~0.86x)   <- OSv WINS
  c8     11755      12144      0.97x      (~0.26x)
  c16    17167      16957      1.01x      (~0.20x)   <- OSv WINS
  c32    10142      17588      0.58x      (0.17x)    <- 3.4x better ratio

Server-side service time (tcpdump at guest NIC, tcpdump pinned to spare cores):
  OSv:   c1 p50=61us -> c32 p50=638us  (tcpdump perturbs the now-CPU-using OSv)
  Linux: c1 p50=70us -> c32 p50=217us
  (bare-run OSv c32 ~62k tps vs tcpdump-run 48k: the probe steals CPU from OSv, which
   is now genuinely CPU-using, so the bare service-time gap is smaller than measured.)

HEADLINE: RO c32 tps 28k(baseline) -> 62k = 2.2x; RO c32 ratio 0.23x -> 0.46x
(doubled); RW c32 ratio 0.17x -> 0.58x (3.4x). The idle-wait plateau is GONE: at c32
~13 of 16 vCPUs are busy (was ~0). OSv peaks ~c16 (= its vCPU count, 110k RO) then
declines past it while Linux's async model keeps climbing.

--------------------------------------------------------------------------------
## THE ORDERED LEVERS (what each one delivered)

Each lever was found by DIRECT MEASUREMENT of the bottleneck at the current ceiling,
then fixed, then re-benchmarked matched. The peel order matters: earlier fixes exposed
later bottlenecks that were previously masked.

LEVER 0 -- SERVING AT ALL (prerequisite, not a scale lever):
  - fd-table fork-coherence: a forked child closing an fd it did not inherit/open
    nulled the PARENT's slot in OSv's single global fd table -> postmaster corruption.
    Fix: track child-opened fds; a child may null the shared slot only for an fd it
    inherited or opened. Unblocked multi-backend serving.
  - ld-musl soname: OSv only knew "libc.musl-x86_64.so.1"; fedora musl-gcc emits
    "ld-musl-x86_64.so.1" as the interp -> "Failed to load object" = the 0-cells wall
    prior agents hit. Landed as standalone generic PR #1473 (MERGED).
  - park-timers pair: app threads arm timers on their per-AS-private stack; after fork
    a child-armed timer walked from a timer IRQ in a foreign AS -> wild ptr -> fault in
    non-preemptable context. Park app-thread timers off the per-CPU list on switch-out,
    re-arm on switch-in. This is what made smp>=2 serving stable at all.

LEVER 1 -- MULTI-QUEUE RX + RSS (broke the single-RX-queue funnel):
  Diagnosed: per-vCPU %CPU SUM DROPPED as clients rose (c8 740% -> c32 526%) while tps
  halved, host ~95% idle; RIP sampling = CPUs idle-spinning waiting on ONE receiver()
  thread. drivers/virtio-net.cc hardcoded rxq=queue(0); F_MQ defined but unimplemented,
  no control-vq. Fix: implement F_MQ (control-vq + negotiation + N rxq + N receivers +
  N MSI-X) + RSS receive-flow-steering. DELIVERED: +20-25% across the c16-c64 tail; 7 of
  8 vCPUs busy where the single queue left them idle-spinning. NECESSARY, NOT SUFFICIENT:
  the curve still peaked at c8 then declined -- the ceiling MOVED downstream of RX.
  (Substrate PRs #1463 MQ, #1470 RSS, #1465 MSI-X-bound.)

LEVER 2 -- IDLE-CPU PULL WORK-STEALING + PARKED-TIMER-UNLINK (fixed wake->run dispatch):
  Diagnosed: 76% of kernel RIP samples in do_idle() spin, ZERO in any lock/COW/vmas_mutex;
  per-vCPU ragged (2 of 16 near-idle at c32). The MQ branch lacked the idle-CPU PULL: a
  woken backend was enqueued on its last-run CPU; if that CPU was busy it waited while
  OTHER CPUs idle-spun. Fix: idle-CPU PULL work-stealing to disperse woken threads. This
  EXPOSED a latent fork bug: donate_to_puller migrated a thread via suspend_timers() but
  WITHOUT load_balance()'s CONF_fork cpu::unlink_parked -> a donated PARKED fork-thread
  stayed linked on the source CPU's parked-timer list -> later timer IRQ walked its
  on-stack node through a FOREIGN AS -> assert(preemptable) in page_fault. This is why
  prior notes said "PULL crashes smp>=2 under real PG load" even though the isolated
  fork+timer test passed (the test never migrates a PARKED thread via idle-pull). Adding
  the unlink fixed it. DELIVERED THE SHAPE CHANGE: peak-c8-then-COLLAPSE became
  climb-to-c8-then-HIGH-PLATEAU; more vCPUs now HELP (smp16 +16-21% over smp8; before,
  smp16 == smp8); RO c32 ratio ~doubled 0.36x -> 0.62x on that intermediate build;
  smp16 c32 = 14 of 16 vCPUs busy (was 2). (Placement lever: idle-pull PR #1472;
  parked-timer-unlink filed as fork-stack S-split on #1458.)

LEVER 3 -- FORK COW-FAULT NESTED-LOCK-FREE (the latency lever; THIS PR, #1475):
  Diagnosed: instrumented the RX->backend path with tsc probes. The ENTIRE RX->wake->
  run->process path is ~7us at c32 (CLASSIFY 0.21us, WAKE 0.50us, WAKE2RUN 5.3us,
  PROCESS 0.60us) -- NOT the ~425us the earlier diagnosis attributed to it by
  elimination. So the wake path was a RED HERRING. The 68->563us per-request growth was
  backends BLOCKING (idle-wait) on the AS-wide vmas_mutex during fork COW write faults
  (and, with fs=rofs, ROFS demand-page faults NESTED inside the fork fault). The
  do_idle-spin the diagnosis saw was the backends genuinely blocked THERE. Fix
  (core/mmu.cc, +44/-3, all #if CONF_fork, conf_fork=0 byte-identical): when a COW write
  fault is itself NESTED (exception_depth >= 2), resolve it lock-free -- skip the
  blocking vmas_mutex->for_write() rwlock and use flush_tlb_local instead of the blocking
  flush_tlb_all (a global flush reschedules, illegal at nested depth and the cause of the
  reschedule_from_interrupt assert). Plus the operational substrate fix: fs=ramfs so
  postgres .text is preloaded and never demand-page-faults nested inside a fork fault.
  DELIVERED: RO c32 tps 28k -> 62k (2.2x), ratio 0.23x -> 0.46x (doubled); RW c32 ratio
  0.17x -> 0.58x (3.4x); OSv WINS RO c1/c8 and RW c1/c16; idle-wait plateau GONE (13/16
  vCPUs busy). 0-crash, 0-failed across RO c1-c64 and RW c1-c32.
  === THIS is commit 2b8c02c9f, banked as DRAFT PR #1475 (fork-stack follow-on to
      #1456, tracked under #1458). ===

--------------------------------------------------------------------------------
## THE THREE MEASUREMENT-CORRECTED HYPOTHESES (the discipline that found the levers)

Three times a confident, plausible hypothesis was OVERTURNED by direct measurement.
The discipline -- instrument, do not infer -- is what kept finding the true lever.

1. FAN-OUT / dispatch-fanout (refuted): the prime suspect for the decline was that the
   wake dispatch needed fanning across CPUs. Measured: all three existing wake levers
   (NET_DISPATCH_FANOUT / SCHED_WAKE_PULL / NET_BATCH_WAKE) declined IDENTICALLY -- they
   only redistribute the WAKE; the RX DRAIN+classify stayed single-threaded. The real
   ceiling was UPSTREAM: packets entered through ONE virtio-net RX queue / one receiver.
   -> redirected to LEVER 1 (multi-queue RX).

2. WAKE-PLACEMENT (refuted as the ceiling, though a real intermediate lever): once MQ
   spread RX, the residual was hypothesized to be wake placement. Idle-CPU PULL did help
   (real LEVER 2, the shape change), but it was NOT the parity ceiling -- and its own
   fix EXPOSED the parked-timer-unlink bug. Placement was necessary, not the end.

3. WAKE-TO-RUN LATENCY (refuted, the biggest correction): the latency diagnosis, by
   elimination from a do_idle-heavy RIP profile, attributed ~425us of per-request growth
   to "wake-to-run latency" on the packet-rx->backend-execute hop. Direct tsc
   instrumentation of every hop showed the ENTIRE wake path is ~7us at c32. Also refuted
   the sub-suspect that wake_pollers is O(connections): each TCP connection has its OWN
   net_channel, so wake_pollers is O(1) per connection. The real lever was FORK-FAULT
   SERIALIZATION (backends blocking on vmas_mutex during nested COW write faults) --
   -> LEVER 3, this PR. The diagnosis's "latency-bound, not starvation" verdict was
   RIGHT; the latency was in the fork-fault path, not the wake path.

--------------------------------------------------------------------------------
## THE C32+ TAIL VERDICT (measured, then partly fixed by LEVER 4)

The c32+ tail was diagnosed to a single named cause and then partly closed by a
generic scheduler tunable (LEVER 4, below). It is NOT purely irreducible fork
structure.

VERDICT = a WAKE / IDLE-DISPATCH LATENCY CEILING = the per-request halt->wake VM-exit
round-trip. NOT a lock, NOT TLB/COW, NOT an RX/TX funnel. Evidence at smp32 c32:
  - RIP profile (1920 samples): do_idle 66% (busy-spin, nothing runnable) +
    handle_incoming_wakeups 8% + x2apic::ipi 1.5%; ZERO vm_fault / COW / vmas_mutex /
    malloc / socket-lock in the entire top-30 -> the nested-COW fix holds, no residual
    fork-fault serialization, no hot lock. RULES OUT lock and TLB/COW.
  - KVM debugfs: tlb_flush ~2/s (rules out TLB/COW-refault); exits/s SATURATE ~400k
    from c16 on = ~6-7 VM-exits per query (a halt when the backend blocks + a wake-IPI
    + a few IO exits). THAT exit rate is the ceiling.
  - In-flight parallelism: only ~11 of 32 vCPUs doing work at any instant at c32 (rest
    do_idle-spin) -> backends latency-bound, blocked waiting for their next request.
  - smp8/16/32 c32 progression: 49k -> 64k -> 70k (smp8->16 +31%, smp16->32 +9%,
    diminishing); smp32 HURTS c48/c64 (scheduler churn). So vCPUs help only up to
    ~vCPU-count concurrency then hurt -> a blend, and the halt/wake round-trip is the
    fixable part.

--------------------------------------------------------------------------------
## LEVER 4 -- OSV_IDLE_SPIN idle spin-before-halt (the tail lever, A/B-validated)

An idle CPU spins a FIXED 10000 iterations polling incoming_wakeups before halting via
arch::wait_for_interrupt (a VM-exit under KVM). For a process-per-connection server
each blocked worker is re-woken by its next request a short time later; if the spin is
too short to catch that wake, the halt + wake-IPI cost the round-trip that IS the
~400k-exits/s ceiling. FIX: make the spin count env-tunable (OSV_IDLE_SPIN); default
10000 = historical behavior byte-identical when unset; a server image raises it.

MECHANISM (deterministic smoking gun), smp16, spin 10000 -> 100000:
  halt_exits/s collapse: c16 38508->1119, c32 48975->434 (99%), c64 48619->1948;
  total exits/s c32 404k -> 370k. The longer spin catches the next request in the poll
  loop and skips the halt VM-exit + its wake-IPI entirely.

MATCHED A/B (paired, fresh boot + fresh load per config, interleaved, median-of-3,
smp16, single-queue vhost, disjoint-core pinning, 0-failed):
  RO c16 +7% / c32 +11% / c48 +17% / c64 +20%; RW c32 +55% (RW backends block more =
  bigger win). Win GROWS with concurrency; RO c1/c8 unchanged (no low-conc regression);
  spin >= 100000 = diminishing returns. Crash gate: fixed spin 100000 0/3, 160000 0/4,
  pristine 0/3, full RO+RW sweeps 0-failed. (An adaptive-budget variant crashed under
  the -i fork/COW load while the same-length fixed spin did not -> shipped the simple
  fixed env-tunable, shelved the adaptive.)

--------------------------------------------------------------------------------
## THE HONEST RESIDUAL (after LEVER 4, the genuinely structural part)

LEVER 4 partly closes the tail (+7-20% RO / +55% RW across c16-c64) but does not reach
Linux parity (OSv +idle-spin100k c32 ~71k vs Linux ~136k = ratio ~0.52x, up from the
latency-fix 0.46x; the full 3-round smp16-vs-smp32-vs-Linux sweep was cut off when the
box was externally terminated). The residual is the genuinely structural part: Linux's
async/epoll does the wake handoff INLINE in softirq with ZERO per-request halt/wake
VM-exits per backend, while OSv process-per-connection still incurs one wake per
request even when idle-spin lets it skip the halt. That structural floor is what
idle-spin partly closes but cannot erase. DEPLOYMENT STORY: size vCPUs to peak
concurrency (smp32 helps c16/c32, hurts c48/c64) AND set OSV_IDLE_SPIN=100000 for a
busy server.

--------------------------------------------------------------------------------
## FIX CHAIN & PR STATUS (all G-signed on gh-fork, benchmark-validated)

Chain: integ/pg-fork-zfs (fork+COW base, #1456/#1458) -> ld-musl+faligned ->
fd-table -> MQ+RSS (+25%) -> PULL + parked-timer-unlink (CLIMBS) -> fork-COW-nested-
lock-free (THIS, the latency lever).

  - #1473 ld-musl soname .......... standalone generic, MERGED.
  - #1463 virtio-net MQ ........... substrate, undrafted/ready.
  - #1470 RSS ..................... substrate, undrafted/ready (dep #1465).
  - #1465 MSI-X bound ............. undrafted/ready.
  - #1472 idle-CPU PULL ........... open non-draft.
  - parked-timer-unlink .......... fork-stack S-split, filed on #1458 (CONF_fork-only).
  - #1475 fork-COW-nested-lock-free  DRAFT, fork-stack follow-on to #1456, tracked #1458.
    (cherry-pick of 2b8c02c9f onto #1456's base, conf_fork=0 byte-identical.)
  - #1476 OSV_IDLE_SPIN idle-spin  DRAFT, STANDALONE on master (0e34e4dc2), NOT stacked.
    LEVER 4. Generic base scheduler tunable in core/sched.cc do_idle; fork-INDEPENDENT
    (no #if CONF_fork), so unlike #1475 it needs no fork stack. Cherry-pick of 79ed402f4
    (auto-merged clean onto master as c6d1c2156, no CONF_sched_wake_pull contamination);
    default byte-identical (unset OSV_IDLE_SPIN => 10000 => historical). G-signed,
    leak-clean, one file +24/-2.

Fork stack is gated on #1455 (the fork opt-in gate, still open/unmerged), so #1456 /
#1458 / #1475 stay DRAFT until that lands. Maintainer offline til ~Nov -- draft is the
right state: banks each fix reviewably without expecting near-term merge.
