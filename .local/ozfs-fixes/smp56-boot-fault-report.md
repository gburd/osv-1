# OSv -smp>=56 boot fault (W1 populate preemptable() assert) - ROOT CAUSE + FIX

Date: 2026-08-04. Box: m5d.metal i-095c6dee173067b4e (beef, us-east-2, local NVMe).
Base: #1458 integ/pg-fork-zfs @ 861be4908 (W1 large-page-descend fix in tree).
Fix commit: 10a62907 (bundle: smp56-entropy-ring-fix.bundle, base 861be4908).

## Symptom (reproduced deterministically)
OSv+PG18 (default shared_memory_type=mmap, shared_buffers 2-8GB) on KVM:
- boots to "ready to accept connections" at -smp 8/16/32/48
- FAULTS deterministically at -smp 56/60/64 with:
    Assertion failed: sched::preemptable() (arch/x64/mmu.cc page_fault:38)
    0x...403881a7 <sched::cpu::idle()+39>
  during PG postmaster startup (right after "starting PostgreSQL 18.0" log,
  as the first fork happens and the shared_buffers populate runs).
Ceiling confirmed 48<->56. Reproduced 2/2 at smp56 AND smp64 (8GB and 2GB SB).

## Console backtrace (addr2line, loader.elf @ 861be4908)
  page_fault              arch/x64/mmu.cc:38            (the assert)
  ex_pf                   arch/x64/entry.S:133          (page-fault exception entry)
  interrupt               include/osv/intr_random.hh:22 (harvest_interrupt_randomness)
  interrupt_entry_common  arch/x64/entry.S:151
  sched::cpu::idle()      core/sched.cc:561             (idle loop, preempt-disabled)

## gdb ground truth (diagnostic build that logs cr2/errcode before the assert, -smp 56)
  W1DIAG cr2      = 0x00002000002023b0   (application mmap slot, VA 0x2000..)
  W1DIAG rip      = 0x00000000402b3bc9   (kernel .text)
  W1DIAG errcode  = 0x3                  (bit0 PRESENT + bit1 WRITE == COW write-fault)
  W1DIAG rflags   = 0x10046              (IF/bit9 == 0 -> interrupts DISABLED)
  W1DIAG preempt  = 1                    (preemption disabled: the idle thread)
  rip 0x402b3bc9 resolves to:
    harvest::harvest(...)                 randomdev_soft.h:54  (memcpy into ring slot)
    ring_spsc::emplace(...)               lockfree/ring.hh:46
    unordered_ring_mpsc<harvest,1024>::emplace(...)  unordered_ring_mpsc.hh:118
    random_harvestq_internal              random_harvestq.cc:164 (ring->emplace(...))
  faulting store: mov %rdi,0x48(%r12)     (write into an entropy ring slot)

## ROOT CAUSE (a general fork-COW-coherence bug, not a W1-fix edge case)
The FreeBSD random-harvest queue allocates its interrupt entropy ring with a
plain `ring = new ring_t();` at boot (random_harvestq_init, random_harvestq.cc:128).
ring_t = unordered_ring_mpsc<struct harvest, 1024>; struct harvest is ~40 bytes,
so the ring is ~40 KB. A malloc of that size is served by malloc_large()->mmap,
which lands in the COW-cloned APPLICATION mmap slot (VA 0x2000..), NOT the
identity kernel heap.

The ring is written on EVERY interrupt: interrupt() (arch/x64/exceptions.cc,
irq-off, preempt-off) -> harvest_interrupt_randomness() -> random_harvestq_internal()
-> ring->emplace(). This is normally harmless.

Under CONF_fork, stock PostgreSQL forks. clone_address_space() COW-write-protects
AS0's private-writable anon pages so a child gets a private copy. The ring page
is such a page, so it becomes PRESENT + read-only (COW pending) in AS0 too. The
very next interrupt-context write to the ring takes a COW write-fault. Breaking
COW requires a faultable context (it may sleep/allocate), so page_fault asserts
preemptable() + IF - both false in interrupt context - and OSv aborts.

The fault surfaces in sched::cpu::idle() because an IDLE cpu (running
preempt-disabled by design, core/sched.cc:554) took the device interrupt.

### Why only >=56 vCPU (the concurrency dependence, not a per-CPU sizing overflow)
It is a probability race, not an array overflow. The window is small: from the
first fork (ring page turns COW) until the ring page's COW is broken by a write.
With more CPUs, more virtio interrupts land on more idle CPUs during the large
shared_buffers mmap-populate, so an interrupt-context write to the still-COW
ring page is reliably hit before the break. At <=48 the tested window did not
hit it; at 56/64 it is deterministic. (max_cpus is 64, cpu_set is one 64-bit
word; the count did NOT overflow any structure at 56 - it is pure timing.)

## FIX (commit 10a62907, #if CONF_fork, conf_fork=0 byte-identical)
Allocate the entropy ring under fork_arena::kernel_heap_scope so malloc_large()
registers the range fork-shared (mmu::add_fork_shared_module_range) and
clone_address_space() maps it VERBATIM (never COW) in every address space -
coherent and writable from every AS and every idle-CPU interrupt path. This is
the same identity/fork-shared routing already used for the ZFS ARC hash arrays
(mempool.cc mapped_malloc_large) and the interrupt-reachable kernel structures
fixed earlier (timers, net_channel pollers, epoll nodes, mbufs, console lines).

  bsd/sys/dev/random/random_harvestq.cc:
    +#if CONF_fork
    +#include <osv/fork_arena.hh>
    +#endif
    ...
    +#if CONF_fork
    +    { fork_arena::kernel_heap_scope _kh; ring = new ring_t(); }
    +#else
         ring = new ring_t();
    +#endif

The #else keeps the original line verbatim, so conf_fork=0 is byte-identical
(modulo assert __LINE__ immediates elsewhere, the established bar). No leak (the
ring lives for the life of the kernel, as before).

## ROUTING (fork-stack vs master)
This is a GENERAL OSv MM / fork-COW-coherence fix, only reachable under CONF_fork
(stock-PostgreSQL fork). It is NOT specific to the W1 large-page-descend logic;
it is the same class as the roadmap's other "interrupt-reachable kernel struct
must be identity/never-COW" fixes. It belongs on the fork stack (#1458
integ/pg-fork-zfs), tagged [fork-stack / CONF_fork]. It is NOT a standalone
master PR: on master (no CONF_fork) the ring is never COW-protected and the bug
cannot occur; the #else path is the unchanged upstream code.

## VALIDATION (m5d.metal, KVM -cpu host, ZFS pool on local NVMe, default mmap 8GB SB)
Boot to "ready to accept connections":
  -smp 8   5/5 READY   (1 transient spin on first sweep, README-known pre-existing
                        nondeterministic boot spin; clean 5/5 on re-run; unrelated
                        to this fix which only touches the entropy ring)
  -smp 32  5/5 READY
  -smp 48  5/5 READY   (W1 <=48 path still works - no regression)
  -smp 56  5/5 READY   (was deterministic crash before the fix)
  -smp 64  5/5 READY   (was deterministic crash before the fix)
  -smp 96  NOT REACHABLE: OSv caps at 64 CPUs by design
           (max_cpus == sizeof(unsigned long)*8 == 64, include/osv/sched.hh:112).
           smp65+ aborts at BOOT with OSv's own message "Too many cpus, can't
           boot with greater than 64 cpus" (boost intrusive-tree assert from the
           cpu_set 1UL<<c overflow for c>=64). Confirmed smp64 READY / smp65 crash.
           This is a separate, pre-existing architectural limit, NOT this fault.

Serving at -smp 64 (default mmap, no sysv):
  psql "select 1" -> 1
  pgbench -i -s10  -> INIT_OK
  pgbench -c8 -T20 -> 72312 transactions, 0 failed, tps=3851

## FILES
  smp56-entropy-ring-fix.bundle  (git bundle: 10a62907 on base 861be4908)
  smp56-entropy-ring-fix.diff    (the one-file diff)
  smp56-boot-fault-report.md     (this report)
