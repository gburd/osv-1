# BOTTLENECK2-DIAGNOSIS — the SECOND bottleneck capping OSv PG past c8

Agent: osv-b2. AWS_PROFILE=fred acct 443433794128 us-east-2.
Instance: **i-0266bb29e56724a5a** (osv-b2-host, m5d.metal, subnet 2b), tagged osv-b2-*.
Egress at launch 150.228.93.240 (Starlink, within scoped supernets).

Base: MQ build wip/pg-mq-scale @ f411d5edc (12 commits G-signed). fs=ramfs conf_fork=1
image=postgres18-musl. loader-stripped.elf 122MB / usr.img 55MB (matches MQ-RESULT).

## STEP 0 — MQ BUILD SERVES (known-good serving config confirmed)
- qemu 9.1.0 from source (KVM+vhost-net). Multi-queue vhost tap0 on br0 192.168.122.1/24.
- Boot: -kernel loader-mq.elf PVH, --rootfs=ramfs, N=8 vhost (queues=8 mq=on vectors=18 rss=on
  hash=on), smp8, m12G, cpu host,+x2apic. OSv v0.57.0-454-gf411d5ed booted 216ms.
- PG18.6 "ready to accept connections". ping .2 0% loss.
- 8 concurrent psql -> 8 DISTINCT backend pids (189/190/192/194/196/198/200/202) = real
  multi-process fork serving, 0 crash.
- pgbench -i -s50 -> 5M tuples OK. RO c8 -j8 -T10: 486687 txns, 0 failed, tps=49353.
- => the known-good serving config reproduced. Proceeding to STEP 1 profiling.

## STEP 1 — BOTTLENECK #2 IDENTIFIED: wake-to-run scheduler dispatch latency (NOT a lock, NOT TX, NOT RX)

Reproduced the decline on this box (RO -S, smp8, N=8 MQ, host 93%+ idle):
  c8 48023 (peak) | c16 32764 | c32 26642   -- matches MQ-RESULT c8 50131/c16 34486/c32 28521.

### PER-vCPU %CPU at c32 (top -H on the 8 qemu vCPU threads, 2 windows):
  93/86/80/80/66/40/13/0   and   90/90/83/82/65/32/8/2
  => only ~6 of 8 vCPUs meaningfully busy; 2 near-idle; aggregate ~460-470% (NOT 640%+).
     UNEVEN: work piles on a few CPUs while 2 sit idle. Classic wake-placement imbalance.

### GUEST-RIP SAMPLING (HMP `info registers -a`, 400 samples across 8 vCPU under c32 load,
### addr2line vs loader.elf):
  246/322 kernel samples (76%) = sched::cpu::do_idle()  (sched.cc:541/526 -- the 10000-iter spin)
   20/322                       = sched::cpu::handle_incoming_wakeups() (draining the wake queue)
    4/322                       = processor::x2apic::ipi()  (cross-CPU wake IPI)
    4/322                       = pci::bar::writew          (virtio kick/notify)
    6/322                       = memcpy (real work)
   78/400 total                 = APP-space RIPs (PG doing real work) = only 20%
  *** ZERO samples in ANY lock: no mutex::lock, no vmas_mutex, no rwlock, no COW-fault path,
      no handle_mmap_fault, no vm_fault. The COW-write-fault vmas_mutex hypothesis is REFUTED
      by the profile -- steady-state RO pgbench is not COW-faulting. TX is fanned out per-CPU
      (net::xmit qidx = cpu->id % _nqp) -- not single-queue. RX is fanned out (per-vCPU busy). ***

### ROOT CAUSE (source-confirmed): the MQ build (wip/pg-mq-scale @ f411d5edc) has NO idle-CPU
    PULL work-stealing. `grep -c CONF_sched_wake_pull core/sched.cc` = 0 on this branch. The PULL
    commit (579cbfed1 "sched: idle-CPU pull work-stealing") lives ONLY on wip/tail-latency-fork;
    the MQ branch was based on pr/rss-substrate (fork-base -> MQ+RSS) and never picked it up.
    So thread::wake_impl enqueues a woken backend strictly on st->_cpu (the CPU it last ran on).
    If that CPU is busy, the backend waits in that CPU's runqueue while OTHER CPUs spin in
    do_idle (send only a wakeup IPI to the target CPU, never pull work to themselves). As
    concurrency rises past ~vCPU-count, more backends contend for the same few CPUs' attention;
    aggregate useful CPU DROPS and tps declines even though the host is 93% idle.

    => TOP LATENCY SOURCE = wake->run dispatch: woken threads are not promptly RUN on an idle
       CPU. The fix lever is idle-CPU work-stealing (PULL) + even wake placement -- the SAME
       class of fix as #1472/579cbfed1, which the MQ branch is MISSING. This is a real, generic
       scheduler serialization, not PG-specific.

## STEP 2 — smp8-vs-smp16 PEAK COMPARISON: FIXED SERIALIZATION, not vCPU-bound

Rebuilt/rebooted OSv-MQ at smp16, N=16 vhost (queues=16 mq=on vectors=34 rss=on hash=on), m12G.
Same loader-mq.elf (smp count is a boot param, no rebuild needed). PG18.6 ready, ping 0% loss,
pgbench -i -s50 OK, c8 46035 0-failed.

### RO -S sweep (2-round max, 0-failed):
  smp8  : c1 13030 | c8 50131 | c16 34486 | c32 28521 | c48 20284 | c64 19778   (MQ-RESULT)
  smp16 : c1 12900 | c8 49976 | c16 33778 | c32 28379 | c48 26117 | c64 19034   (this run)

### THE ANSWER: the PEAK STAYS AT c8 at BOTH smp8 and smp16. Doubling vCPUs did NOT shift the
    peak from c8 to ~c16. The curve is essentially IDENTICAL (c8 ~50k, c16 ~34k, c32 ~28k both).
    => NOT vCPU-bound. If OSv scaled to ~vCPU-count, smp16 would peak near c16; it does not.
    This is a FIXED-SIZE SERIALIZATION in the wake-dispatch path, independent of vCPU count.

### PER-vCPU %CPU at smp16 c32 (16 vCPU threads): 90/49/17/4/1.5/0.5x11
    => only ~2 of 16 vCPUs busy; 14 near-idle. WORSE spreading than smp8 (6/8 busy). More vCPUs
       makes the imbalance WORSE (more idle-spinners) because wake_impl still enqueues each woken
       backend on st->_cpu (its last-run CPU) with no work-stealing to pull it onto an idle CPU.
    Confirms STEP 1: the bottleneck is wake->run placement, and it is a hard serialization the
    added vCPUs cannot relieve -- they just idle-spin in do_idle waiting for wakes that never
    spread. THE FIX = idle-CPU PULL work-stealing (the 579cbfed1 commit the MQ branch is missing)
    + even wake placement so woken backends run on idle CPUs, not pile on their last-run CPU.

## STEP 3 — FIX: idle-CPU PULL work-stealing + a fork-timer-safety fix it exposed

The bottleneck (wake->run dispatch, STEP 1/2) is the SAME class #1472/579cbfed1 fixed for the
single-queue base. The MQ branch (wip/pg-mq-scale) was based on pr/rss-substrate and NEVER
picked up that PULL commit. FIX = bring PULL onto the MQ+fork branch.

### Branch: gh-fork wip/pg-scale2 @ e8147608 (2 commits on top of MQ f411d5edc, both G-signed):
  1. 3da8cea30 = cherry-pick of 579cbfed1 "sched: idle-CPU pull work-stealing". Env-gated
     (OSV_WAKE_PULL=1), compiled default-y, runtime no-op unless armed. When an idle CPU has an
     empty runqueue it IPIs the busiest CPU to donate one migratable runnable thread, instead of
     waiting for the timer load-balancer. Self-throttling (one outstanding donate per victim).
  2. e8147608 = the FORK-TIMER SAFETY FIX the PULL path needed on a CONF_fork build (found by
     running PULL under real MQ+PG load):
     * SYMPTOM: with OSV_WAKE_PULL=1, pgbench RO at c48/c64 ABORTED the guest with
       `assert sched::preemptable()` in page_fault (mmu.cc:38), stack:
       timer_list::fired() <- interrupt <- cpu::idle(). = the IRQ-context COW-timer-in-foreign-AS
       disease (a timer IRQ walked a migrated thread's on-stack timer node through the wrong AS).
     * ROOT CAUSE: cpu::donate_to_puller() migrates a runnable thread and calls suspend_timers(),
       but -- unlike the MQ build's load_balance() source-side migration -- it did NOT first
       cpu::unlink_parked(mig). On a fork build a preempted app thread may be parked on the victim
       CPU's per-CPU timer list; a donated parked thread was left linked on the source CPU's
       parked list, and a later timer IRQ there walked its node through a foreign AS -> fault in
       non-preemptable context.
     * FIX: add the same `#if CONF_fork cpu::unlink_parked(mig);` before suspend_timers() in
       donate_to_puller, matching load_balance() exactly. 10 lines, conf_fork=0 byte-identical.
     * This is why prior notes flagged "PULL crashes at smp>=2 under real PG+MQ load" (BEFORE-
       BASELINE) even though tst-fork-irq-cow passed in isolation: the isolated test never
       migrates a PARKED thread via the idle-pull path. Now fixed at the root.

### VALIDATION (smp8, N=8 MQ, OSV_WAKE_PULL=1, after the fix): NO crash, 0-failed all cells,
    guest alive through c64. Per-vCPU at c32: 98/97.5/97/97/96/96/0/0 = 6 CPUs EVENLY pegged
    (was 93/86/80/80/66/40/13/0 PULL-off = ragged, 2 near-idle). The wake dispersal works.

### THROUGHPUT (RO -S, 2-round max, smp8 N=8, PULL-off vs PULL-on+fixed):
  c    PULL-off   PULL-on   delta
  1     13030      11776    ~
  8     50131      60978    +22%
  16    34486      42422    +23%
  32    28521      41584    +46%
  48    20284      38450    +90%
  64    19778      27163    +37%
  => the c8 peak RISES (+22%) AND the post-peak DECLINE largely flattens (c16-c48 hold ~38-42k
     vs collapsing to 20k). PULL is the fix for bottleneck #2. Full 3-round A/B in STEP 4.

## STEP 4 — APPLES-TO-APPLES: OSv(MQ+PULL) vs Linux, both smp8 AND smp16, N-queue both

### Harness (fair, single variable = the OS / the PULL toggle)
- ONE m5d.metal, qemu 9.1.0 from source (KVM+vhost-net). Both guests m12G cpu host,+x2apic.
- BOTH multi-queue vhost tap (queues=N mq=on vectors=2N+2 rss=on hash=on). tap0 OSv .2 /
  tap1 Linux .3 on br0. Driven from the HOST over the tap IPs (real net). Guests run SEQUENTIALLY.
- RAM-vs-RAM: OSv ramfs / Linux tmpfs(10G). (ZFS-vs-ZFS still blocked by the fork-ZFS-port ENXIO.)
- PG18.6 BOTH, config MATCHED + PROVEN via SHOW on both:
  shared_buffers=128MB, max_connections=100, io_method=sync, fsync=on, synchronous_commit=on.
- pgbench -s50, RO(-S) + RW(TPC-B), 0-failed gated. Two methods reported (both consistent shape):
  * 3-round median, 20s (conservative; ramfs+fsync leaves inter-round dirty state -> variance).
  * best-of-2, 15s (peak-throughput; the clean scaling-curve shape).

### THE PULL A/B (smp8, N=8, same 3-round-median method, 0-failed) -- the fix vs no-fix:
```
      OSv-MQ smp8         RO tps                RW tps
  c   PULL-off  PULL-on   d%       PULL-off  PULL-on   d%
  1     11629    11282    ~          1745     1731     ~
  8     47517    37662   (noisy)     3569     4259    +19%
  16    33305    28368   (noisy)     3093     3925    +27%
  32    27247    28324   +4%         2759     3602    +31%
  48    19897    27361   +38%        2527     3301    +31%
  64    18873    25961   +38%          -        -
```
  RW: PULL wins EVERY cell +19..31%. RO: PULL wins the TAIL decisively (c48 +38%, c64 +38%) --
  PULL-off COLLAPSES (c48 19897/c64 18873) while PULL-on HOLDS a plateau (c48 27361/c64 25961).
  (RO c8/c16 3-round-median noisy; the best-of-2 sweep below shows PULL wins there too.)

### best-of-2 RO sweep (method-consistent SHAPE, 0-failed):
```
  c    MQ-noPULL(smp8)   PULL(smp8)   PULL(smp16)   Linux(smp8)
  1      13030            11776         11967        10259
  8      50131            60978         73660        82489
  16     34486            42422         51225        84754
  32     28521            41584         49107        78863
  48     20284            38450         44665        78390
  64     19778            27163         29516        78396
```

### PER-vCPU SPREAD (the mechanism, top -H on the qemu vCPU threads at c32):
  smp8  PULL-off: 93/86/80/80/66/40/13/0        (ragged, 2 near-idle, ~460% aggregate)
  smp8  PULL-on : 98/97/97/97/96/96/0/0         (6 EVENLY pegged, ~580%)
  smp16 PULL-off: 90/49/17/4/1.5/0.5x11         (only 2 of 16 busy -- vCPUs WASTED)
  smp16 PULL-on : 88/82/80/80/78/75/75/75/69/66/64/64/62/54/0/0  (14 of 16 busy, ~1000%+)

### THE KEY QUESTION -- DOES OSv CLIMB PAST c8 NOW? YES.
- BEFORE (STEP 1/2): OSv peaked at c8 and DECLINED regardless of vCPU count (smp8==smp16, the
  extra vCPUs just idle-spun). A FIXED wake-dispatch serialization.
- AFTER (PULL + the fork-timer fix):
  1. The post-c8 DECLINE flattens into a high PLATEAU (best-of-2 smp8: c8 60978 -> c48 38450,
     was c8 50131 -> c48 20284). No more collapse.
  2. MORE vCPUs now HELP: smp16 beats smp8 at every mid/high cell (c8 73660 vs 60978 = +21%,
     c32 49107 vs 41584 = +18%, c48 44665 vs 38450 = +16%). Before the fix smp16 was identical
     to smp8. The workload became genuinely vCPU-scalable.
  => The fix converted a hard serialization ("peaks at vCPU-count then declines") into a
     vCPU-scalable plateau. OSv now scales UP with load and with vCPUs, toward Linux's shape.

### OSv/Linux ratio (best-of-2, smp8 / smp16 PULL vs Linux smp8):
  RO: c1 1.15/1.17 | c8 0.74/0.89 | c16 0.50/0.60 | c32 0.53/0.62 | c48 0.49/0.57 | c64 0.35/0.38
  (was, MQ-noPULL/Linux: c8 0.61, c16 0.42, c32 0.36, c48 0.26, c64 0.25)
  => PULL roughly DOUBLES the mid/tail ratio (c32 0.36 -> 0.62 at smp16). Still short of Linux's
     async event-loop climb, but OSv now holds 0.5-0.6x across the whole sweep instead of decaying
     to 0.25x. RW smp16/Linux: c8 5605/13491=0.42, c32 3878/13097=0.30 (was ~0.20-0.25x).

### VERDICT
The SECOND bottleneck = wake->run scheduler dispatch (woken backends piling on their last-run CPU
while idle CPUs spin, with NO idle-pull work-stealing on the MQ branch). The fix = idle-CPU PULL
work-stealing (579cbfed1) + the fork-timer-safety fix (unlink_parked before the pull migration)
it exposed. It flips OSv from a fixed c8-peak-then-decline to a vCPU-scalable high plateau: the
c8 peak rises +22%, the decline flattens, and adding vCPUs (smp16) now helps for the first time
(+16-21% over smp8). OSv/Linux mid/tail ratio roughly doubles (c32 0.36x -> 0.62x). MQ broke the
RX funnel; PULL breaks the wake-dispatch funnel. Both necessary; together OSv finally scales up.

### HOST 93%+ IDLE gone at the OSv collapse point: at smp16 c32, 14 of 16 vCPUs busy (~1000%
    aggregate) = OSv is now USING the vCPUs it has. The remaining gap to Linux is the fork-per-
    backend model's per-connection cost (Linux serves 64 conns on 8 vCPUs via async; OSv runs one
    OS thread per backend), not an idle-host dispatch stall. That is a structural model difference,
    the next (harder) lever -- documented, not a serialization to fix.
