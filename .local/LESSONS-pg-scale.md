# Lessons: PostgreSQL-scale-on-OSv diagnose to fix arc

Copyright (C) 2026 Greg Burd

Durable capture of the scale-under-load campaign so the arc is not forgotten.
Host-local only. The reusable fixes are banked as PRs / gh-fork branches:

    integ/pg-fork-zfs (#1458 fork stack)
      -> wip/cow-fork-irq-fix   (ld-musl soname + faligned; soname split out as PR #1473)
      -> wip/pg-scale-fix       (fork child fd-table ownership)
      -> wip/pg-mq-scale        (virtio-net MQ #1463 + RSS #1470)
      -> wip/pg-scale2          (idle-CPU PULL #1472 + parked-timer-unlink, fork stack S-split)

Benchmark shape change (real forking PG, matched OSv-vs-Linux, QEMU single/N-queue
vhost tap, real net, RAM-vs-RAM, 0-failed c1-c64): from "peaks c8 then declines to
0.23x at c32" to "climbs to c8 then holds a high plateau, c32 ~0.62x, RW wins every
cell". Residual gap to Linux = the fork-per-backend structural model, not a bug.


## 1. The "regression" was never a regression

The old "good" number (RO c32 ~0.51x) was measured on a base with NO fork
machinery: `fork()` returned ENOSYS (sys_clone rejected any clone without
CLONE_THREAD). PostgreSQL is multi-process (postmaster forks one OS process per
backend), so on that base PG could not fork real backends. That number measured a
strictly EASIER workload: one shared address space, no COW faults, no cross-AS
timers, no fork arena.

The later build pays the full multi-process fork cost the old base never paid.
So the apparent 2x "regression" (0.51x -> 0.23x) is apples-to-oranges: it is the
COST OF CORRECTNESS, the first time real forking PG was measured at all. The
trustworthy parity baseline is the real-forking build, not the non-forking one.

LESSON: before trusting a before/after, confirm both runs actually did the same
work. A number from a build that silently no-ops the hard path (ENOSYS fork) is
not a baseline, it is a different, easier benchmark wearing the same name.


## 2. The scale bottlenecks peeled in a strict order

Each fix exposed the next ceiling; none was visible until the one above it was
removed:

  (a) WAKE PLACEMENT. Woken backends enqueued on their last-run CPU; if busy they
      waited while other CPUs idle-spun. The 100ms load balancer was far too slow
      to disperse a fan-out of short-lived worker threads. Fix: idle-CPU PULL
      work-stealing on the idle entry (#1472).

  (b) SINGLE RX-QUEUE FUNNEL. All inbound packets entered through one virtio-net
      RX queue and one receiver() thread on one CPU. Aggregate guest CPU DROPPED
      as clients rose while throughput halved. Fix: multi-queue RX (F_MQ, #1463) +
      RSS flow steering (#1470): N queues, N receivers, flows hashed across CPUs.

  (c) WAKE-TO-RUN DISPATCH LATENCY on the MQ branch. The MQ branch was built off
      the RSS substrate and LACKED the PULL work-stealing from (a). MQ spread RX
      to 7/8 CPUs but the woken backends still piled onto their last-run CPU. Fix:
      cherry-pick the PULL work-stealing onto the MQ branch (wip/pg-scale2).

  (d) [RESIDUAL, not a bug] FORK-PER-BACKEND STRUCTURAL COST. With (a)-(c) fixed,
      all locks / RX / TX / COW / wake paths are ruled out or fixed (RIP sampling
      showed zero time in any lock/vmas_mutex/vm_fault). OSv now uses its vCPUs
      (14 of 16 busy at c32, was 2). The residual gap to Linux's async climb is
      that each PG connection is a forked OS process with a COW address space,
      versus Linux's lighter async/thread-pool path. This is an architectural
      property of PG-multiprocess-on-a-unikernel, the next STRUCTURAL lever, not a
      serialization to fix.

LESSON: a scaling collapse on an idle host is a stack of serializers, not one bug.
Fix the top one, re-measure, and the shape of the NEXT one appears. Do not guess
the second bottleneck while the first still dominates the profile.


## 3. The PULL + fork crash mystery (why the isolated test passed)

The idle-CPU PULL path (`donate_to_puller`) migrated a thread via
`suspend_timers()` but, unlike `load_balance()`'s source-side migration, did NOT
`cpu::unlink_parked()` it first. A donated PARKED fork-thread was therefore left
linked on the SOURCE CPU's per-CPU parked-timer list. A later timer IRQ on that
CPU walked the migrated thread's on-stack timer node through a FOREIGN address
space and faulted in non-preemptable context -> assert(preemptable()) in
page_fault.

This is why earlier notes said "PULL crashes smp>=2 under real load" even though
the dedicated fork+timer regression test (tst-fork-irq-cow) PASSED at smp1/2/8:
the isolated test never migrates a PARKED thread via the idle-pull path, so it
never linked a parked node cross-CPU-then-migrated. Only real forked backends
under concurrency (parked on a WaitLatch/poll timeout, then donated to an idle
CPU) hit it.

Fix: mirror `load_balance()`'s `#if CONF_fork cpu::unlink_parked(mig)` in
`donate_to_puller`. conf_fork=0 byte-identical. `unlink_parked` is a safe no-op if
the thread is not parked. This is the parked-timer-unlink commit, filed as a
fork-stack S-split (references machinery that only exists on the fork build).

LESSON: a passing regression test that does not exercise the exact interaction
(here: migrating a PARKED thread via idle-pull, not via the 100ms balancer) is not
coverage. When two independently-correct features (PULL + park-timers) combine,
the bug lives in the seam neither test crosses. Enumerate the state a feature can
migrate (parked vs runnable) and confirm the test drives each.


## 4. Diagnostic methods that actually worked

  - GUEST-RIP SAMPLING. qemu monitor `info registers -a`, resolve the guest RIP
    with addr2line against loader.elf, bucket the samples. do_idle() spin % is the
    single best signal: high do_idle spin on an idle host = wake-dispatch
    starvation (CPUs have nothing to run because woken threads are queued
    elsewhere), NOT a CPU limit and NOT a lock (a lock shows time IN the lock, not
    in do_idle). This ruled out locks/COW/vmas_mutex decisively (ZERO samples
    there) and pointed straight at dispatch.

  - PER-vCPU BUSY%. Ragged distribution (93/86/80/80/66/40/13/0) = serialization /
    poor placement (some CPUs starved). Even distribution across all vCPUs =
    vCPU-bound (real work, add vCPUs). The transition from ragged to even is the
    proof a dispatch fix worked (2-of-16-busy -> 14-of-16-busy).

  - smp8-vs-smp16 PEAK TEST. If the throughput peak SHIFTS right with more vCPUs,
    the bottleneck is vCPU-bound (more CPUs help). If the peak STAYS at the same
    concurrency at both smp8 and smp16, it is a FIXED serialization independent of
    core count (the wake-dispatch funnel: peak stayed at c8 at both until PULL was
    added, then smp16 finally beat smp8).

  - HOST IDLE% AT COLLAPSE. Host ~95% idle while guest throughput falls = a
    scaling/dispatch bottleneck INSIDE the guest, fixable, not a host CPU floor.
    A saturated host would mean a real resource limit. This one number separates
    "fixable dispatch bug" from "out of CPU".

LESSON: sample where the CPU IS, do not theorize where it might be. do_idle spin %
+ per-vCPU busy ragged/even + peak-shift-vs-stays + host idle% together localize a
scaling bug to placement / RX-funnel / dispatch / real-CPU without touching the
code.


## 5. The universal fork rule (the one disease behind them all)

Any object that a forked child AND the parent (AS0) or a sibling both touch
cross-address-space must be COHERENT or IDENTITY-mapped. Every fork bug in this
campaign was a violation of this one rule:

  - TIMERS: a thread arms sched::timer on its per-AS-private user stack
    (nanosleep/poll/epoll_wait). After fork, parent and child have DIFFERENT
    physical stacks at the SAME virtual address. A child-armed timer left on the
    per-CPU list while the CPU runs a different AS is dereferenced through a
    FOREIGN AS -> wild pointer -> fault in the non-preemptable timer IRQ. Fix:
    park app-thread timers off the per-CPU list on switch-out (their own AS), and
    unlink them on ANY migration (load_balance AND donate_to_puller, see item 3).

  - FDs: OSv has a single GLOBAL fd table. A forked child closing an fd it neither
    inherited nor opened-after-fork nulled the PARENT's slot -> postmaster
    corruption. Fix: track child-opened/inherited fds; a child may null the shared
    slot ONLY for an fd it owns, else no-op.

  - .data / .bss / GOT: a forked child must see the parent's CURRENT initialized
    globals, not the pristine ELF image. On OSv this is already correct (load_segment
    mmap_populates writable file-backed segments; relocate_pltgot eager-binds all
    PLT in AS0 pre-fork; .bss populated writable + COW-shared). A "NULL app global
    in the child" report here was a false alarm (a debug patch), but the rule stands.

  - SHARED-ANON (PG shared_buffers / catalog): must be coherent across sibling
    backends, not private COW copies, or a backend memcmp-reads a stale/zero page.

LESSON: when a fork bug appears, do not chase the symptom (which pointer faulted).
Ask: what object do the child and parent/sibling both touch across the AS boundary,
and is it coherent or identity? The fix is always "make that object identity-mapped
or explicitly coherent", and the smallest fix is at the shared choke point (the
timer list, the fd table), not at each caller.
