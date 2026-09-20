# TAIL-DIAGNOSIS — the c32+ scalability tail on OSv PG (agent osv-struct)

Instance: **i-0d978ada3d74c9fb4** (osv-struct-host, m5d.metal 96 vCPU, us-east-2, subnet 2b).
Base build: **wip/pg-lat-fix @ 2b8c02c9f** (MQ+PULL+parked-timer + nested-COW-lock-free), conf_fork=1
fs=ramfs image=postgres18-musl, qemu 8.1.3 KVM, single-queue vhost tap0, PG18.6, WAKE_PULL=ON.
NUMA-clean: OSv pinned node0 (cores 0-15 for smp16), mem membind node0; pgbench driver pinned node1
(cores 24-47); host = m5d.metal 2-socket (node0=0-23,48-71 / node1=24-47,72-95). 0-failed all cells.

## VERDICT: (a)+(d) blended = a WAKE/IDLE-DISPATCH LATENCY CEILING, NOT a lock (c) and NOT TLB/COW (b).
The c32+ tail is the per-request **halt->wake VM-exit round-trip** (the scheduler idle/wake path),
which saturates the guest's exit rate. More vCPUs help the mid-range (c16/c32) with diminishing
returns but HURT the deep tail (c48/c64) via scheduler churn. NOT relieved to parity by vCPUs
(rules out pure-(a) oversubscription) and NOT fixed-flat (rules out pure-(d)). NOT a lock, NOT
memory/COW/TLB.

## STEP-1 MEASUREMENTS

### RIP profile (guest vCPU sampling via qemu monitor info-registers, addr2line vs loader.elf)
smp16 c32 (768 samples): do_idle 51% | handle_incoming_wakeups 17% | x2apic::ipi ~3% | app/kernel 32%.
smp32 c32 (1920 samples, function-agg of top 30 RIPs):
  do_idle 1266 (66%) | handle_incoming_wakeups 156 (8%) | x2apic::ipi 28 (1.5%) | atomic-load 20 |
  cpu_set-ctor 6 | pci-bar-write 6 | switch_to 5 | x2apic::eoi 4 | memcpy 8.
  *** ZERO vm_fault / page_fault / vmas_mutex / COW / malloc-arena / mutex / socket-lock in the
      entire top-30. The nested-COW-lock-free fix (2b8c02c9f) holds -- no residual fork-fault
      serialization, no lock hot at c32/smp32. RULES OUT (b) and (c). ***
  do_idle is a busy-SPIN poll loop (returns instantly when a thread becomes runnable) -> "66% in
  do_idle" = 66% of cycles SPINNING with nothing runnable = backends idle-waiting for the next
  request round-trip, NOT starved-of-CPU.

### In-flight parallelism (non-idle vCPUs per RIP snapshot)
smp16 c32: ~7.9 of 16 vCPUs doing work at any instant (rest spin in do_idle).
smp32 c32: ~10.9 of 32 vCPUs doing work at any instant.
=> useful parallelism SATURATES ~11 backends in-flight; a c32 closed loop with ~0.45ms round-trip
   can only keep ~11 backends busy -- the rest block waiting for their next request (network
   round-trip + the OSv wake handoff). Doubling vCPUs 16->32 only raised in-flight 7.9->10.9.

### Context-switch rate (perf stat -a -C 0-15, 12s window)
c16: 6,280/s | c32: 3,914/s | c64: **31,379/s (8x jump)**. cpu-migrations 661/474/1137.
=> ctx-switch is modest at c16/c32; EXPLODES at c64 (4x-oversubscribed) = scheduler thrash begins
   only in the deep tail. Not the c32 bottleneck; a c64 contributor.

### KVM exit reasons (debugfs /sys/kernel/debug/kvm, 8s delta, smp16)
  c    exits/s   halt_exits/s  halt_poll_ok/s  tlb_flush/s  tps
  c1   30,112    12,276        10,595          18           11,408
  c16  399,990   38,508        34,866          2            63,064
  c32  403,591    48,975       43,632          2            64,210
  c64  375,808    54,296       31,573          12           56,804
*** DECISIVE:
  1. tlb_flush ~2/s at c16-c64 (essentially ZERO) -> RULES OUT (b) TLB pressure / COW re-faults.
  2. exits/s SATURATES ~400k from c16 on -> the guest hits a VM-exit-rate ceiling. ~400k/64k tps =
     ~6-7 VM-exits per PG query (a HALT when the backend blocks + a wake interrupt + a few IO exits).
     THAT exit rate is the throughput ceiling.
  3. halt_exits climb 12k->38k->49k->54k = more idle-wait round-trips per second as concurrency
     rises; halt_poll (KVM's adaptive halt-polling) tracks it. The halt->wake cycle per request IS
     the tail cost. ***

### smp8 / smp16 / smp32 c32 progression (the disambiguator: do vCPUs lift c32?)
  RO c32 tps:  smp8 49,225  |  smp16 64,397  |  smp32 70,286
  (smp8->16 = +31%, smp16->32 = +9% = DIMINISHING). NOT climbing to Linux parity (Linux c32 ~136k).

### Full smp x concurrency matrix (RO tps, single-round, driver node1, 0-failed)
  c     smp8     smp16    smp32
  c1    11938    11724    11059
  c8    62043    66582    66778
  c16   50931    63470    70631
  c32   49225    64397    70286
  c48   -        60389    41474   <- smp32 WORSE than smp16 in the deep tail
  c64   -        56411    38205   <- smp32 WORSE (32 vCPUs thrash the wake dispatch)
  latency grows ~linearly with c (smp16: c8 0.12ms / c16 0.25 / c32 0.50 / c64 1.13ms) while tps
  is a FLAT plateau -> closed-loop Little's Law: tps ~= conc/latency EXACTLY (c32: 32/0.497ms=64k).

## WHY (a)+(d) blend, not pure (a) or pure (d)
- If pure (a) OVERSUBSCRIPTION: smp32 would lift c32 toward parity (~2x). It only gave +9%, and
  smp32 HURT c48/c64. So vCPUs are not the lever past ~vCPU-count concurrency.
- If pure (d) FIXED STRUCTURAL: vCPUs would not move c32 at all. But smp8->16 gave +31% and
  in-flight rose 7.9->10.9. So there IS headroom up to ~vCPU-count concurrency.
- The real ceiling: the per-request HALT->WAKE round-trip caps useful in-flight backends at ~11
  and caps VM-exits at ~400k/s. OSv's process-per-connection PG blocks each backend between
  requests; each unblock is a halt-exit + wake-IPI + context-switch = ~6-7 VM-exits/query. Linux's
  async/epoll model does the same handoff INLINE in softirq (no per-request halt/wake VM-exit
  round-trip per backend), so it keeps climbing to c32+.

## IS THERE A LEVER? (STEP-2 decision)
The 8-17% in handle_incoming_wakeups + x2apic::ipi + the 66% do_idle-spin are the wake/idle path.
Candidate levers (measured-first, per the discipline that corrected 3 prior hypotheses):
  - do_idle busy-spin vs halt: OSv spins in do_idle before halting. Halt-polling is KVM-side
    (halt_poll_ok tracks halt_exits). The spin itself burns node0 cycles but is not the ceiling
    (the ceiling is the exit RATE, which is the halt/wake round-trip count, not the spin duration).
  - The per-request halt/wake round-trip is structural to process-per-connection blocking backends.
    Reducing VM-exits/query (e.g. longer adaptive spin before halt so a fast-arriving next request
    avoids the halt/wake exit entirely) is the one plausible generic lever -> STEP 2 tests it.

## ============================================================================
## STEP-2 LEVER FOUND + FIXED + A/B-VALIDATED (then box externally terminated mid-STEP-3)
## ============================================================================
## THE LEVER: the spin-before-halt count in sched::cpu::do_idle(). An idle CPU spins a FIXED
## 10000 iterations polling incoming_wakeups, then halts via arch::wait_for_interrupt (a KVM
## VM-exit). For process-per-connection PG, each blocked backend is re-woken by its next request a
## short time later; if the spin is too short to catch that wake, the halt + wake-IPI cost a
## round-trip of ~6-7 VM-exits/request -- which IS the ~400k-exits/s throughput ceiling STEP-1 found.
##
## FIX (gh-fork wip/pg-tail-fix @ 79ed402f4, off wip/pg-lat-fix 2b8c02c9f, G-signed, leak-clean):
## core/sched.cc -- make the spin count env-tunable (OSV_IDLE_SPIN). Default 10000 = historical
## behavior BYTE-IDENTICAL when unset; a server image raises it. +24/-2 lines, one file.
##
## MEASURED A/B (paired: fresh boot + fresh pgbench -s50 per config, INTERLEAVED default-vs-spin,
## median-of-3, smp16, single-queue vhost, NUMA-clean node0 guest / node1 driver, 0-failed):
##   RO c16: default 62973 -> spin100k 67471  (+7%)
##   RO c32: default 63954 -> spin100k 70998  (+11%)
##   RO c48: default 59870 -> spin100k 70377  (+17%)
##   RO c64: default 55957 -> spin100k 67218  (+20%)
##   RW c32: default 10202 -> spin100k 15823  (+55%)   <- RW backends block more -> bigger win
##   The win GROWS with concurrency (more halt/wake round-trips avoided). RO c1/c8 unchanged
##   (no low-concurrency regression). spin=500000 ~= spin=100000 (diminishing past 100k).
##
## KVM-EXIT MECHANISM (deterministic, the smoking gun), smp16, spin 10000 -> 100000:
##   halt_exits/s: c16 38508->1119, c32 48975->434 (99% collapse!), c64 48619->1948.
##   total exits/s: c32 404k -> 370k. => the longer spin CATCHES the next request in the poll loop
##   and skips the halt VM-exit + its wake-IPI entirely. That is exactly the ceiling STEP-1 named.
##
## CRASH GATE (heavy pgbench -i -s50 index-build fork/COW load, the IRQ-COW-timer hazard path):
##   fixed spin 100000: 0/3 crashes. fixed spin 160000: 0/4 crashes. pristine (10000): 0/3.
##   => the env-tunable FIXED spin is crash-safe at every tested value + full 0-failed sweeps.
##   REJECTED VARIANT: an ADAPTIVE per-CPU budget (grow-on-catch/shrink-on-halt, bounded
##   [10000,160000]) CRASHED under the -i load (assert(preemptable) page_fault:38 = the
##   IRQ-COW-timer disease) while the SAME-length FIXED spin (100000/160000) did NOT -- so the
##   crash was the adaptive logic's extra path, not spin length. Shipped the simple fixed
##   env-tunable (proven safe), shelved the adaptive (buggy, and a magic-number-free story not
##   worth a scheduler race).
##
## VERDICT REFINED: the c32+ tail was (a)+(d)-blend = a per-request HALT/WAKE VM-EXIT round-trip
## ceiling. It is PARTLY a real, generic, FIXABLE lever (this fix, +7-20% RO / +55% RW at the tail,
## 0-failed) -- NOT purely irreducible fork-per-backend structure. The RESIDUAL after this fix is
## the genuinely structural part (Linux's async/epoll does the same handoff inline in softirq with
## zero per-request halt/wake VM-exits per backend; OSv's process-per-connection blocking backend
## still incurs one wake per request even when it doesn't halt).
##
## STEP-3 (full smp16-vs-smp32 A/B vs Linux) INCOMPLETE: the m5d.metal box (i-0d978ada3d74c9fb4)
## was EXTERNALLY terminated ("User initiated shutdown", not by this agent) at 06:26 GMT mid-run,
## after both guests were up (OSv PG18.6 spin-fix + Linux PG18.6 PGDG, config-SHOW-matched
## RAM-vs-RAM) and the OSv legs + the paired idle-spin A/B were banked. Linux smp16 c32 baseline
## from the prior matched A/B = ~136k (OSv spin100k c32 ~71k => ratio ~0.52x, up from lat-fix 0.46x).
## The smp8/16/32 c32 OSv progression (49k/64k/70k, banked above) already answered the
## disambiguator: more vCPUs help c16/c32 with diminishing returns and HURT c48/c64 (scheduler
## churn) -- so the tail is a wake/dispatch-latency ceiling, not pure oversubscription.
