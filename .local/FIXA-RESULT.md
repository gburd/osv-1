# FIX A — shared-anon fork write-fault AS-lock elimination — RESULT (in progress)

## Instance
- instance-id: **i-0b28696ff27ab932c** (m5d.metal, us-east-2, real bare-metal KVM /dev/kvm, 96 vCPU, 377G RAM, 4x838G NVMe)
- acct 840154381708 (beef). Public 18.190.24.244 / private 172.31.19.110.
- Build: OSv @ 6b71c76385 base + RCU-registry fix + FIX A + LOCKPROF, image=zfs-tools,pg18-fork
  fs=zfs conf_zfs=openzfs conf_fork=1, DEFAULT mmap. Wake-steal EXCLUDED (pure 6b71 sched.cc)
  to match regsplit isolation. lockprof=1.
- FIX A toggle: env OSV_MMU_COW_PEEK (1=on default, 0=old for_write-every-write-fault). One image, clean A/B.

## THE FIX (generic, core/mmu.cc, #if CONF_fork)
vm_fault() write-fault path took as->vmas_mutex->for_write() on EVERY write fault just to call
handle_cow_write_fault() (which walks to the leaf PTE, returns false for a non-COW page). For a
shared-anon (MAP_SHARED|ANON) page the leaf is either empty (first touch, installed under for_read)
or present+pte_shared+writable (never a COW copy) -> the AS-wide write lock is pure waste and
serializes ALL faults in that AS. FIX A: lock-free peek of the leaf PTE (walk_to_leaf, shared with
handle_cow_write_fault, DRY); take for_write ONLY when the leaf is genuinely pte_is_cow. Private-COW
path unchanged. Generic: benefits ANY MAP_SHARED|ANON+fork workload, zero PG awareness.

## Microbench (GENERIC, app-agnostic proof) - misc-fork-shared-anon-faults.cc
mmap(MAP_SHARED|ANON) 512MB, fork 32 children, each madvise(DONTNEED)+write-faults its 1/32 slice
repeatedly (sustained write-fault storm through the shared-anon path). A/B via OSV_MMU_COW_PEEK.
(first run had too-short loops for LOCKPROF; re-running with LOOPS=200 for sustained pressure.)

## STATUS: images built (PG loader 73MB + tests), seed cluster (initdb+pgbench -s50) ready, tap0 up.

## BASELINE (COW_PEEK=0 = 6b71+RCU, FIX A OFF) - default mmap, tap0 192.168.100.2, DUR=60s, smp32
  ro c1=14626  c8=87988(peak)  c16=25853  c32=19178  c48=18551  c64=18122   <- THE COLLAPSE (peak c8, drops hard)
  rw c1=1369   c8=4316 ...
  LOCKPROF @ c32 RO: vmas_write=93% / 2.50s  <== the wall (regsplit said 72%/2.58s; reproduced+dominant)
                     registry_shard=5% (RCU reads, uncontended), page_ranges=0%, vmas_read=0%
  REGSPLIT: fast_hits=10.8M fast_misses=210k insert_real=210k insert_lock_blocked=42 (registry SOLVED)

## Boot nondeterminism note: zfs_mount faults if the pool was left dirty (unclean pkill). FIX: restore a
   cleanly-exported pool snapshot (pgdata-clean.raw) before each boot. Clean pool -> ready attempt 1.

## pgbench must come from fedora postgresql-contrib (v15, wire-compatible); plain postgresql pkg lacks it.

## FIX A (COW_PEEK=1) - same sweep
  ro c1=11898  c8=85138  c16=27225  c32=20048  c48=18862  c64=19097
  rw c1=1459   c8=4256   c16=3320   c32=3160   c48=2930   c64=2760
  LOCKPROF @ c32 RO: vmas_write=88% (calls=31517)  <== STILL the wall, STILL ~same call count

## PER-CELL DELTA (FIXA vs BASELINE, RO):
  c1:  11898 vs 14626  (-19%, c1 noise/boot variance)
  c8:  85138 vs 87988  (-3%)
  c16: 27225 vs 25853  (+5%)
  c32: 20048 vs 19178  (+4.5%)
  c48: 18862 vs 18551  (+2%)
  c64: 19097 vs 18122  (+5%)
  RW: within noise every cell (no regression, no gain).

## VERDICT: FIX A is a NULL on PG (all cells within ~5% noise). The collapse does NOT flatten.

## ROOT CAUSE (the diagnosis premise was wrong): the PG hot write faults are PRIVATE-COW faults,
   NOT shared-anon faults. write_fault_needs_cow_lock() returns TRUE for them (pte_is_cow==true),
   so FIX A correctly leaves them on the for_write copy path (they genuinely need the private copy).
   vmas_write call count is ~identical baseline(32367) vs fixa(31517) -> the peek did NOT divert them.
   The registry (shared-anon reads) is 10.8M fast_hits, uncontended (regsplit was right there).
   But the WALL is the ~31k private-COW page COPIES under the AS-wide write lock, held ~76us each,
   serializing all faults in that AS. shared_buffers (MAP_SHARED) is shared-not-COW at fork; the COW
   pages are PG backends' inherited PRIVATE pages (local catalog caches / memory contexts) written
   post-fork -> a genuine COW copy each.

## MICROBENCH PROVES THE MECHANISM (app-agnostic): when faults ARE truly shared-anon, FIX A drops
   for_write acquisitions 43256 -> 57 (99.9%). So FIX A works for shared-anon+fork workloads; PG's
   wall just isn't shared-anon, it's private-COW.

## THE REAL PG WALL = private-COW copy under AS-wide write lock. A generic fix would be per-page /
   lock-free COW copy install (cmpxchg the new PTE under for_read instead of the AS-wide for_write),
   OR a range/per-vma lock. That is a DIFFERENT generic fix (FIX A', the COW-copy path) - the peek
   correctly identifies these as COW; making the COW COPY itself not need the AS-wide lock is the lever.
