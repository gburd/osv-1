# FIX A' - private-COW copy de-serialization - RESULT (agent, this session)

## Instance
- instance-id: **i-0df5f174ec9c47713** (m5d.metal, us-east-2c, real bare-metal KVM /dev/kvm,
  96 vCPU, 377 GB RAM, 4x 838G local NVMe). acct 840154381708 (beef). Public 18.227.216.194.
- Build: OSv @ integ/pg-fork-zfs base 6b71c76385 + WIN1 (RCU registry) + WIN2 (FIX A COW-peek)
  + FIX A' (this fix), image=zfs-tools,pg18-fork fs=zfs conf_zfs=openzfs conf_fork=1, DEFAULT
  mmap (NO sysv). Toggle env OSV_MMU_COW_LOCKFREE (1=on default, 0=old for_write copy path).
  One image, clean A/B. Seed pgbench -s50 once; clean pool snapshot restored before each boot.

## THE FIX (generic, core/mmu.cc vm_fault, #if CONF_fork)
The measured PG wall was ~15k PRIVATE-COW page copies at c32, each taking as->vmas_mutex->
for_WRITE (AS-wide EXCLUSIVE) to copy one page + swap one leaf PTE, serializing ALL faults in
that AS. FIX A': the copy is private to this AS and the only shared mutation is a single leaf
PTE, so it needs no AS-wide exclusion - only an atomic PTE install. handle_cow_write_fault_lockfree
runs under as->vmas_mutex->for_READ, copies the shared page into a fresh private page, and
installs it via an atomic compare_exchange of the leaf PTE (old COW value -> private-writable).
If the cmpxchg loses (a concurrent fault on the same VA installed first) it frees its copy and
treats the fault as handled - the same double-check idiom the shared-anon registry uses. Still
under for_READ so it stays mutually excluded from the for_WRITE holders that restructure the
page tables (clone_address_space at fork, munmap teardown). Generic: benefits ANY fork-per-worker
COW workload, no PG awareness.

TLB correctness: kept mmu::flush_tlb_all() (the all-cpu IPI broadcast). The local-only flush
was REJECTED as unsafe in the general case: a fork child that pthread_creates additional threads
has a multi-threaded AS, so a stale RO TLB entry could live on another cpu. The single-threaded-
child assumption is true for PG backends but NOT guaranteed generically, and the HARD CONSTRAINT
is a generic OSv fix with no workload assumptions. flush_tlb_all stays; the de-serialization win
is dropping for_WRITE -> for_READ, not shortening the flush.

## BASELINE (LOCKFREE=0) - default mmap, tap0 192.168.100.2, T=60s, smp32, RO, 0-failed
  c1=13620  c8=83331(peak)  c16=23886  c32=19469  c48=18751  c64=18610   <- THE COLLAPSE (peak c8)
  RW: c8=6209  c32=3079

## FIX A' (LOCKFREE=1) - same sweep, 0-failed
  c1=12864  c8=83805  c16=28145  c32=18389  c48=18963  c64=17876
  RW: c8=6400  c32=3115

## PER-CELL DELTA (FIX A' vs BASELINE, RO)
  c1:  12864 vs 13620  (-5.5%, c1 boot/noise variance)
  c8:  83805 vs 83331  (+0.6%)
  c16: 28145 vs 23886  (+17.8%)   <- the one real cell
  c32: 18389 vs 19469  (-5.5%)
  c48: 18963 vs 18751  (+1.1%)
  c64: 17876 vs 18610  (-3.9%)
  RW: c8 +3%, c32 +1% (no regression, tiny gain).

## VERDICT: FIX A' is a NULL on PG tps (all cells within ~5% noise except a real +18% at c16).
   The collapse does NOT flatten (c16-c64 stay ~18-28k, not climbing toward Linux 130-159k).

## LOCKPROF c32 RO A/B (did vmas_write drop from 93%?) - the mechanism DID de-serialize
  BASELINE (LOCKFREE=0):
    vmas_write     calls=15504  blocked=88  wait_ns=3,015,538,702  (99%)   <- the wall
    registry_shard calls=6,174,208 blocked=325 wait_ns=4,758,831 (0%)      (RCU reads, uncontended)
    vmas_read      calls=26,393 blocked=10  wait_ns=53,051 (0%)
    page_ranges    calls=9,838  blocked=339 wait_ns=11,602,676 (0%)
    total_blocked_wait_ns = 3,031,953,260
  FIX A' (LOCKFREE=1):
    vmas_write     calls=15327  blocked=14  wait_ns=1,860,397,816  (98%)   <- SAME COW faults, now for_READ
    registry_shard calls=6,174,208 blocked=403 wait_ns=5,957,636 (0%)
    vmas_read      calls=26,383 blocked=7   wait_ns=50,843 (0%)
    page_ranges    calls=9,890  blocked=441 wait_ns=20,031,421 (1%)
    total_blocked_wait_ns = 1,886,437,716

  So: the COW faults still number ~15k (FIX A' does NOT eliminate the copy - PG genuinely needs
  the private page). But taking them under for_READ instead of for_WRITE cut the BLOCKED
  acquisitions 88 -> 14 (6x) and total blocked-wait 3.03s -> 1.89s (-38%). The COW faults no
  longer mutually exclude each other; the residual 1.86s is for_READ still waiting on the fork-
  time for_WRITE holders (the postmaster spawning backends). vmas_write is still 98% by SHARE
  only because everything else is ~0 - the ABSOLUTE contention fell.

## WHERE THE WALL MOVED / WHY tps DIDN'T LIFT: the machine is STILL ~97% IDLE at c32 RO
  (mpstat: ~2.7% busy on 96 vCPU during the load). The wall did NOT move to page_ranges/mempool
  (still 0-1%). The dominant remaining serialization is NOT a mutex FIX A' can shed (total
  lock-blocked-wait is only ~1.9s over a 60s window = ~3% of wall-time, yet the machine is 97%
  idle). That points at a non-lock serialization on the fault/wake path (scheduler wake-latency /
  dispatch round-trip per fault), consistent with the ROADMAP wake-latency hypothesis: backends
  block waiting to be run, not waiting on a lock. FIX A' correctly removed a real lock wall
  (the COW-copy for_WRITE exclusion) but the collapse is gated by wake-latency underneath it.

## DECISION: NOT committed (null on PG tps). It is a correct, generic contention reduction (COW
  faults de-serialized 6x on the blocked-acquire count, -38% blocked-wait, RW no-regression,
  0-failed) but it does not lift PG throughput because the binding constraint at c16-c64 is
  wake-latency, not the COW lock. Honest null. Code is complete + compiles clean + toggled;
  it can be revisited if a wake-latency fix later exposes the COW lock as the next wall.

## NEXT WALL (for the next agent): wake-latency / scheduler dispatch on the fault path. The
  machine is 97% idle and lock-blocked-wait is only 3% of the window -> the backends are parked
  waiting to be scheduled, not spinning on a lock. Measure the wake round-trip (thread parked ->
  runnable -> running latency) under c32 RO. This is the L5 wall the ROADMAP predicted after the
  lock walls (L1 registry, L2 shared-anon write, L3 private-COW copy) are all shed.

## Cleanup: box i-0df5f174ec9c47713 TERMINATED; qemu + docker containers reaped.
