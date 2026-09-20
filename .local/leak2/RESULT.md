# LEAK #2 RESULT (agent-leak2b, box i-0d75e6472ec9328ea, m5d.metal us-east-2)

## VERDICT
1. fix_striped.py (the AS-tied identity-heap fallback tracker) FAILS the 3-way gate:
   it CRASHES (unikernel-specific double-free of kernel vfs objects). DID NOT SHIP.
2. The corrected-design candidate "bounded g_bump top-rewind" is MEASURED NON-VIABLE:
   a greedy top-rewind reclaims only 8.8% of the carved arena. NOT built.
3. The real leak is reproduced clean on a control arm (mem_free 23042 -> 5351 MB,
   ~0.77-1.8 MB/backend, 300+ rounds, no crash). Corrected-design recommendation below.

Nothing banked, no PR touched, no branch pushed. Box terminated, 0 orphans.

================================================================================
## PART 1 - fix_striped.py FAILS: the THIRD flaw (unikernel app-vs-kernel indistinguishability)
================================================================================

### Setup (all clean)
- Base gh-fork bench/leakhunt @ ac6a389d (leak #1 fd fix + OSV_LEAK_PROBE), apps @ 3f93f43
  (seed_copy `mkdir(dst,0700)` grep=1), ZFS @ 6330a45b. instrument.py + fix_striped.py
  applied; verified in BUILT source (fb_track_insert/erase/fork_arena_free_as_fallbacks
  x12 mempool.cc, arena_reclaim_on hh+cc, reap hook x2 mmu.cc, fb line leak_probe.cc).
  Built CONF_fork=y, loader has OSV_FORK_ARENA_RECLAIM + 9 fix symbols. Clean.
- integ.sh: 8KB-unique-payload md5 + prefix-bleed check, 32 conns, 320 rounds,
  autovacuum ON, io_method=sync. A/B by OSV_FORK_ARENA_RECLAIM.

### 3-way gate, per arm (real LEAKPROBE lines in ON-console.log / OFF-console.log)

ARM A - FIX ON (default):
- (a) mem_free FLAT: PASS until crash. Arena exhausted ~round 100 (arena_used_mb=512),
      fb_mb 0->24GB tracked, mem_free FLAT ~22929 MB through round 170 (ok=32). Leak stopped.
- (b) NO WEDGE: **FAIL - ABORT ~round 175 (probe t=110):**
        FATAL: could not open file "base/16384/PG_VERSION": EIO   (storm)
        Aborted
          osv::handle_mmap_fault <- mmu::vm_fault <- page_fault
          <- vrele+114 <- drele+174 <- file::~file()+107 <- vfs_file::~vfs_file()
          <- osv::rcu::cpu_quiescent_state_thread::do_work()
      LEAKPROBE thread FROZE at t=110; all later rounds ok=0 fail=32.
- (c) totalCORRUPT=0: PASS (rounds 1..170).

ARM B - FIX OFF (OSV_FORK_ARENA_RECLAIM=0) [CONTROL]:
- Ran FULL 320 rounds, NO abort, NO wedge, CORRUPT=0.
- mem_free MONOTONIC (the leak): R10=23042 -> R100=18132 -> R200=12609 -> R320=5351 MB.
- fb_mb (would-be-tracked identity fallback) 652 -> 50015 MB. ~0.77-1.8 MB/backend -> OOM.

| metric                | FIX ON                     | FIX OFF (control)        |
|-----------------------|----------------------------|--------------------------|
| mem_free post-exhaust | FLAT ~22900 MB             | monotonic 23042 -> 5351  |
| leak                  | STOPPED                    | ~0.77-1.8 MB/bkd -> OOM  |
| wedge/crash           | ABORT ~round 175 (RCU UAF) | none, all 320 rounds ok  |
| totalCORRUPT          | 0 (rounds 1..170)          | 0 (all 320)              |
| gate                  | (a)PASS (b)FAIL (c)PASS    | leak baseline            |

Control is decisive: the crash is caused BY the fix's reap-free; the leak is real.

### ROOT CAUSE - the third flaw, and it is UNIKERNEL-SPECIFIC (the key new constraint)
The tracker records every identity-heap fallback made while
`sched::cpu::current()->app_thread==true && current_address_space()!=kernel`.
OSv is a unikernel: THE KERNEL RUNS ON THE APP THREAD. During a child backend's
open() syscall, the kernel does `new vnode()` / dentry / file alloc with app_thread=true
and current AS = the child. Post-exhaustion those KERNEL objects fall to the identity
heap and get recorded under the child AS. On reap, fork_arena_free_as_fallbacks(as)
free()s them - but those vfs objects are refcounted and freed by the kernel's OWN
RCU-deferred path (file::~file -> drele/vrele). The reap free is a DOUBLE FREE; the RCU
quiescent-state thread then dereferences the freed vnode -> page_fault -> Abort.

Both PG app malloc() (relcache/catcache) and kernel `operator new`/`new vnode()` funnel
through the SAME core/mempool.cc malloc -> std_malloc app-thread arena branch. At that
point there is NO marker to tell "the backend's leaked app heap" (reap it) from "a
kernel vfs object" (kernel frees it, must NOT reap). force_kernel_heap/kernel_heap_scope
is wrapped only around explicit global-memory critical sections (e.g. zio_t in OpenZFS),
NOT around vfs allocation - so it does not gate vnodes.

=> The tracker's premise "child-AS identity-heap fallbacks == the backend's leaked app
heap" is FALSE. The set also contains kernel objects with independent RCU/refcount
lifetimes. Reap-freeing the whole set double-frees them. NO amount of striping, larger
FB_AS_PER, or per-AS chains fixes this - they change throughput, not WHICH objects get
freed. The prior single-global-lock WEDGE (~round 60) was a different (throughput)
symptom that masked this UAF: the slow lock never reaped far enough post-exhaustion to
hit a tracked vnode before falling over on contention. The tracker-reap family is a dead
end for kernel objects in a unikernel.

================================================================================
## PART 2 - the reframe + the g_bump-rewind MEASUREMENT
================================================================================

### Reframe (correct, and the code confirms it)
The arena ALREADY handles BOTH app and kernel objects correctly PRE-exhaustion. Routing
(mempool.cc): alloc -> arena iff (fork_arena::ready && !force_kernel_heap && child).
Before g_bump exhausts, PG app heap AND kernel vfs objects both go to the arena; arena
free() pushes to the per-AS Treiber freelist; release_as drops the freelist heads; the
child's physical pages are freed by page-table teardown. Kernel objects RCU-freed later
hit arena free() = a freelist push into the (now-cleared, still-mapped-in-AS0-BSS)
head - benign. No leak, no crash. The FLAT pre-exhaustion phase in BOTH arms proves it.
THE ENTIRE PROBLEM IS POST-EXHAUSTION FALLBACK TO THE IDENTITY HEAP, where release_as no
longer covers the app heap AND the double-free hazard appears.

=> The fix is NOT a reap-tracker. It is: MAKE THE ARENA NOT EXHAUST, so the identity-heap
fallback (and its double-free hazard) never happens. g_bump marches monotonically to
g_end and never rewinds even though each dead child's PHYSICAL pages are freed on
release_as - only the VA leaks.

### The decisive experiment: is the carved VA reclaimable AT THE TOP of g_bump?
Instrumented fork_arena.cc (carve_measure.py): per-AS [lo,hi) carve watermark; on
release_as classify TOP (hi==g_bump, rewindable) vs BURIED (younger live carve above),
and simulate a greedy top-rewind (rewind past every contiguous fully-dead top region),
counting reclaimed bytes. Built clean (CONF_fork), ran 300-round churn (CARVE-console.log).

RESULT (steady state, arena fully carved):
    carved_mb=511   rewound_mb=45   reap_top=6   reap_buried=271   reap_nocarve=~9200
    carve_recs=173  (distinct ASes that ever carved; ~9200 reaped ASes never carved)

  - A greedy top-rewind reclaims only 45 of 511 MB = **8.8%**. Nowhere near bounded.
  - Only **6 reaps (2.2%)** had their carve at the top; **271 (97.8%)** were BURIED.
  - rewound_mb plateaus at 45 MB EARLY and never grows: the 6 top reaps happen while the
    arena is still filling; once full, the topmost region is pinned by a long-lived AS
    (postmaster / a long backend), so nothing rewinds past it. Permanently fragmented.
  - Guest ran all 300 rounds, no crash (base arena, no tracker; matches OFF arm).

=> **The carve pattern is INTERLEAVED, not LIFO. Bounded g_bump top-rewind is NON-VIABLE
   (8.8%).** PG backends do not die in reverse-birth order under churn; short-lived
   backends carve above long-lived ones and die first, leaving buried holes a top-rewind
   cannot touch. (This is exactly the "not reclaimable-at-top" case the steer named.)

================================================================================
## PART 3 - corrected-design recommendation (for a fresh-context build run; NOT built here)
================================================================================
Both cross-AS-VA-reuse designs (VA-reclaim, per-AS overflow region) crashed on the
load-bearing invariant: free() CROSSES address spaces (AS0 reaper / sibling / later
child), so any VA that free() must touch BY RANGE and that is mapped only in the dead
child faults. And the tracker-reap family is unsafe (Part 1). And top-rewind is
non-viable (Part 2). The honest remaining options, in order:

(A) BEST: per-AS overflow region whose free() does NOT read the chunk header cross-AS.
    When the shared arena exhausts, a child bumps from its OWN private app-slot VA
    region (COW-isolated, freed wholesale by destroy_address_space page teardown - the
    SAME mechanism release_as already relies on). The crash of the earlier per-AS-overflow
    attempt was free() reading the chunk's size/class header at a VA unmapped in the
    freeing (AS0/sibling) context. FIX THAT SPECIFICALLY: store the size/class metadata
    OUT-OF-LINE in kernel BSS keyed by (rounded VA), or make free() of an overflow-region
    pointer a NO-OP (the whole region is reclaimed by page teardown on reap, so per-object
    free is unnecessary - just recognize "this VA is in an overflow region" by range check
    against BSS-recorded per-AS region bounds and return without touching the page). The
    range check reads only kernel BSS, never the (possibly-unmapped) chunk page -> no
    cross-AS fault. This keeps app AND kernel objects in the child's private region;
    kernel objects RCU-freed later also hit the no-op free -> no double-free, no leak
    (page teardown frees them). This is the design that respects every invariant.
    Validation gate unchanged: mem_free FLAT + NO wedge to round 300 + totalCORRUPT=0,
    PLUS a targeted check that a reaped child's overflow region is fully unmapped and a
    later child's overflow region does not alias it.

(B) STOPGAP: enlarge the arena (e.g. 512MiB -> several GiB) to push exhaustion far past
    any realistic connection-churn budget. Bounded, trivial, correct (no new free path),
    but only defers the wall; not a real fix. Acceptable only as a documented interim.

Do NOT pursue: g_bump top-rewind (8.8%, Part 2); the identity-heap reap-tracker (Part 1
UAF); naive cross-AS VA reuse (prior crashes). Option (A) with out-of-line/no-op free is
the recommended build for the next run.

## EVIDENCE FILES (.local/leak2/)
- ON-console.log / ON-integ.log        - fix ON, the RCU-vfs-double-free abort ~round 175
- OFF-console.log / OFF-integ.log       - fix OFF control, clean 320-round leak curve
- CARVE-console.log / CARVE-integ.log   - g_bump carve/rewind measurement (8.8% rewindable)
- carve_measure.py                      - the measurement instrument (reusable)
- fix_striped.py, instrument.py         - the applied (failed) fix + probe

## BOX
- i-0d75e6472ec9328ea (m5d.metal, us-east-2, Owner=agent-leak2b) - TERMINATED, 0 orphans.
