# cwwake RESULT: the OSv PostgreSQL VU64 "wedge" is an OUT-OF-MEMORY exhaustion, not a lost wakeup

## BOXES (Owner=agent-cwwake, us-east-2) — TERMINATE at end, confirm 0 orphans
- METAL: i-0618ded3135fde01c  m5d.metal  (OSv guest + host + instrumentation)
- DRV:   i-068bdb1b424a15250  c5.4xlarge (HammerDB VU64 driver)

## HEADLINE (measured, honesty-gated)
The dominant OSv PostgreSQL-on-ZFS VU64 residual is **NOT a completion->waiter lost-wakeup deadlock**
(the brief's premise). It is an **out-of-memory exhaustion**: the OSv guest (given -m 64G) is driven to
~2.8 MB free in ~40-50s under VU64, the memory reclaimer cannot free further, and it **OOM-panics** in
`memory::reclaimer::do_reclaim` (guest then goes fully dark: network "No route to host").

**Bug-vs-cost verdict: COST, not a bug.** The exhaustion is the SUM of a large shared_buffers base +
the legitimate per-backend private footprint of ~74 concurrent forked PG backends, exceeding 64GB. It is
NOT a memory leak, NOT a lost condvar wakeup, and NOT a fork MAP_SHARED COW-duplication bug (OSv's
shared-anon fork-coherence machinery works correctly — see below).

## HOW THE LOST-WAKEUP PREMISE WAS REFUTED (the reclaim-stall symptom trap)
The initial "smoking gun" DID look like a lost wake:
  `ZWEDGE LOST-WAKE zcw=0x60085471e100 blocked_ms=418.3 zcw_done=1 (completion RAN, waiter STILL ASLEEP)`
A ZIL commit-waiter blocked in the untimed `cv_wait(&zcw_cv)` with `zcw_done==1` (completion ran +
cv_broadcast fired) yet still asleep — the textbook lost-wakeup signature. BUT it was a **symptom of the
memory-reclaim stall** (the waiter is blocked while the reclaimer spins unable to free memory), not a
dropped condvar wake. Proof: **six** wake-path A/Bs ALL still "wedged" (i.e. all still OOM'd), which is
impossible if any of them were the cause:
  1. OSV_ZIL_FLUSH_INLINE=1  (collapse the flush-completion INTERRUPT-taskq hops)   -> still OOMs
  2. OSV_CONDVAR_NO_MORPH=1   (wake cv waiters directly, bypass wait-morphing/RHO)   -> still OOMs
  3. OSV_WAKE_IPI_ALWAYS=1 v1 (drop send_wakeup_ipi runqueue<=1 suppression)         -> still OOMs
  4. OSV_WAKE_IPI_ALWAYS=1 v2 (unconditional IPI + incoming_wakeups_mask bypass)     -> still OOMs
  5. OSV_ZIL_WAIT_TIMEOUT=1   (untimed cv_wait -> 1ms-recheck cv_timedwait_hires)    -> still OOMs
  6. OSV_IDLE_SPIN=2e9        (vCPUs never deep-halt; qemu pinned 3205% spinning)    -> still OOMs
The `OSV_ZIL_WAIT_TIMEOUT` result was the tell: a waiter self-rechecking `zcw_done==1` every 1ms MUST
proceed — unless the whole guest is memory-dead. The clean (non-gdb) console then showed the OOM abort
directly.

## THE OOM, MEASURED (per-pool trajectory names it)
qemu RSS (guest physical footprint), VU64 worker, sb=16G, -m 64G:
  t=6s  36.3GB (37 backends)  ->  t=24s 53.8GB (74 backends, maxed)  ->  t=30s 61.5GB (backends FLAT,
  RSS still climbing)  ->  t=48s 67.2GB (>64G) -> OOM PANIC.
In-guest MEMPROBE (free / ARC / dirty) as free collapses 64GB -> 0.5GB:
  ARC stays <= 2GB (WAY under its 32G cap) — **NOT the ARC** (confirmed: ARC=8G cap A/B still OOMs).
  zfs_dirty_data_max fixed at 3.2GB and honored — **NOT dirty-data** (write throttle works).
  ARC(2) + dirty(3.2) + shared_buffers(16) ~= 21GB accounted; the other ~42GB is anonymous/private
  memory across the 74 backend fork-child address spaces (~600-800MB/backend).

## BUG-VS-COST: the decisive shared_buffers A/B
- sb=16G VU64: free collapses 64GB->0.5GB -> **OOM panic** at ~t45-48s.
- sb=1G  VU64: **NO OOM**, free floor ~17GB, oscillates 17-43GB (reclaim keeps up), runs the full timed
  test to completion ("Test complete, Taking end Transaction Count"), 74 backends, guest stays alive.
Reconciliation that settles it:
- The ~600-800MB/backend private footprint is present at BOTH sb=16G and sb=1G (RSS reached ~65GB even at
  sb=1G) => that footprint is genuine per-backend PRIVATE working memory, NOT shared_buffers.
- shared_buffers behaves as a FIXED BASE (one shared copy: 16GB vs 1GB), NOT a per-backend multiplier =>
  OSv's fork MAP_SHARED coherence for anon shared_buffers (`shared_anon_registry`, core/mmu.cc:1844) is
  WORKING: shared_buffers is one shared physical copy across all backends, not COW-duplicated.
- OOM = base(shbuf + ARC + kernel) + N_backends x per-backend-private. At sb=16G the sum > 64G -> OOM;
  at sb=1G the 15GB-smaller base leaves reclaim headroom -> healthy.
=> **COST, not a bug.** Correctly sized (sb=1G), OSv runs PostgreSQL-on-ZFS at VU64 to completion on the
   identical stack that OOM'd at sb=16G.

## WHY VU64 not VU32; why Linux scales
Per-backend footprint is ~linear in backend count. VU32 (~40 backends) fits in 64G at sb=16G; VU64
(~74 backends) does not -> OOM. Concurrency-proportional threshold between VU32 and VU64. Linux at the
same 64G/sb=16G/VU64 scales because its per-backend fork footprint is smaller (real fork with shared page
tables and lighter per-process anon), so base + 74 x (smaller per-backend) stays under 64G. The
OSv-specific angle is that OSv's per-backend fork footprint (COW page-table clone + per-AS private anon)
is HIGHER than Linux's — that is the real OSv scaling *cost* to reduce, but it is a cost characteristic,
not a discrete bug.

## FIX / MITIGATION
Immediate (sizing, no code): size guest RAM >= base(shared_buffers + ARC) + N_backends x per-backend
(~0.7GB) + reclaim headroom; or cap max_connections / shared_buffers to fit; sb=1G proves VU64 completes.
Real OSv improvement (harder, general): reduce the per-backend fork footprint — shrink COW page-table
clone cost and per-AS private anon so N backends fit in less RAM (would lift the VU64+ ceiling and help
any high-fan-out forked workload). That is the next engineering target, and it is a memory-management
improvement, not a scheduler/wake fix.

## WHAT THE BRIEF GOT RIGHT AND WRONG
Right: VU64 is the dominant residual; it is OSv-specific; Linux scales on the same host.
Wrong: it is not a ZIL/condvar/scheduler lost-wakeup. The zcw_done=1+asleep signature is real but is a
reclaim-stall symptom. Chasing the wake layer (six A/Bs) was necessary to *exclude* it; the measurement
(the OOM console line + the per-pool memory trajectory) corrected the premise.

## INSTRUMENTATION LEFT (all env-gated, default-off; on gh-fork bank/zil-completion-wake-fix if pushed)
- OSV_ZIL_WEDGE_PROBE (zil.c): done-but-asleep watchdog + fifo-state scan (the reclaim-stall symptom capture)
- OSV_MEM_PROBE (arc_os.c): per-pool memory trajectory (free/ARC/arc_c/dirty) — the pool-naming tool
- OSV_WAKE_IPI_ALWAYS, OSV_CONDVAR_NO_MORPH, OSV_ZIL_WAIT_TIMEOUT: the refuted-hypothesis A/B knobs
These are diagnostics; none is a fix. Evidence files: .local/cwwake/cells/EVIDENCE-*.txt
