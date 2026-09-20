# cwwake: ZIL completion->waiter lost-wakeup deadlock root-cause

## BOXES (Owner=agent-cwwake, us-east-2)
- METAL: i-0618ded3135fde01c  m5d.metal  admin@3.144.12.89  priv 172.31.9.251  (OSv guest + host + instr)
- DRV:   i-068bdb1b424a15250  c5.4xlarge ubuntu@18.188.148.166 priv 172.31.1.191 (HammerDB VU64 driver)
- SG sg-0a0fec26afe57cd43 (ingress: 22->73.4.58.126/32, 5432->intra-SG; egress 0.0.0.0/0 = fine)
- MUST terminate both + confirm 0 orphans + 0 available volumes at end.

## STATUS LOG
- launched boxes.
- host-setup done, build done (114M img, PG present). APPS 3f93f43, ZFS 6330a45b.
- io_method=io_uring NOT supported by this PG build (only sync/worker) -> using WORKER (brief says worker wedges identically, may trace easier).
- seeded ZFS pool (ashift=12, fresh initdb 420K), exported OK.
- HammerDB 6.0 installed on driver (correct asset: HammerDB-6.0-Prod-Lin-UBU24.tar.gz), schema build 200wh running.

## KEY SOURCE FINDINGS (pre-measurement)
- ZFS commit-waiter path is race-free at the ZFS layer: zil_commit_waiter loops while(!zcw_done) holding
  zcw_lock; zil_commit_waiter_done sets zcw_done=TRUE under zcw_lock then cv_broadcast. Classic
  signal-before-wait (hyp a) IMPOSSIBLE. Lost wake must be inside OSv condvar/wake machinery (b/c/d).
- The DEADLOCK branch: zil_commit_waiter's UNTIMED cv_wait(&zcw_cv) (lwb already ISSUED). No timeout to
  self-heal -> if the flush completion's cv_broadcast wake is lost here, sleeps forever. This is where the
  ~66 WALWrite backends pile up.
- PRIOR ART patch 0040 (OSV_ZIL_FLUSH_INLINE, IN THE BUILD): documents the completion takes TWO serial
  cross-vCPU thread hops on OSv (blk-completion-thread -> INTERRUPT taskq -> re-dispatch lwb_root_zio ->
  INTERRUPT taskq again -> zil_lwb_flush_vdevs_done -> cv_broadcast). FLUSH_INLINE=1 collapses those hops
  (runs completion inline on blk thread). This is the A/B for hypothesis (d): completion runs on a
  taskq/zio thread whose cross-vCPU wake to the halted backend is lost. If FLUSH_INLINE=1 kills the wedge
  -> root cause = lost cross-vCPU wake on the taskq->backend hop.
- OSv send_wakeup_ipi() SUPPRESSES the IPI when runqueue.size()>1 (trusts target to self-reschedule) or
  idle_poll true. Candidate lost-wake site if a target never reschedules.

## PLAN
1. baseline reproduce VU64 wedge (worker). confirm signature.
2. A/B: OSV_ZIL_FLUSH_INLINE=1 -> wedge gone? (no rebuild needed, 0040 in build)
3. wedge probe (patch 0044, done-but-asleep smoking gun) -> rebuild -> capture proof.
4. fix at root + validate.

## ***ROOT CAUSE CORRECTED (measured): the VU64 wedge is an OUT-OF-MEMORY PANIC, not a lost wakeup***
The honesty-gate probing overturned the brief's lost-wakeup premise. Evidence chain:
- BASELINE (worker VU64) WEDGE REPRODUCED: healthy ~30-60s then cliff ~t45-75s, PG unresponsive, NEVER
  recovers. cells/EVIDENCE-baseline-wedge.txt
- Initial smoking gun LOOKED like a lost condvar wake: ZWEDGE LOST-WAKE zcw_done=1 + waiter asleep 418ms
  (cells/EVIDENCE-SMOKING-GUN-lost-wake.txt). But it was a SYMPTOM of a reclaim stall, NOT a lost wake.
- FIVE wake-path A/Bs ALL still wedged (=> none was the cause): FLUSH_INLINE=1, CONDVAR_NO_MORPH=1,
  WAKE_IPI_ALWAYS v1, WAKE_IPI_ALWAYS v2 (unconditional IPI + incoming_wakeups_mask bypass),
  ZIL_WAIT_TIMEOUT=1 (1ms recheck), OSV_IDLE_SPIN=2e9 (never deep-halt, qemu pinned 3205% spinning).
- THE REAL CAUSE (console, clean non-gdb run): "Out of memory: could not reclaim any further. Current
  memory: 2868 Kb" + backtrace in memory::reclaimer::do_reclaim + page-faults on all CPUs. Post-cliff the
  guest NETWORK is DOWN ("No route to host") = kernel OOM-PANIC, not a blocked PG. This is why every wake
  A/B "failed" - none addressed OOM. cells/EVIDENCE-OOM-IS-ROOT.txt

## POOL NAMED (measured, MEMPROBE per-pool trajectory): fork-COW / anonymous memory
- qemu RSS (cells/EVIDENCE-memory-trajectory.txt): 36->54GB as backends fork 37->74, then KEEPS climbing
  54->67GB with backends FLAT at 74 -> write-driven growth independent of fork count -> OOM at >64GB.
- MEMPROBE (cells/EVIDENCE-POOL-NAMED-forkCOW.txt): free_MB collapses 64GB->0.5GB while ARC stays <=2GB
  (NOT the ARC) and zfs_dirty_data_max fixed 3.2GB (throttle OK, NOT dirty). ARC(2)+dirty(3.2)+shbuf(16)
  ~=21GB accounted; ~42GB UNACCOUNTED = anon/fork-COW across 74 backend child ASes (~570MB/backend).
- ARC=8G cap STILL OOMs (cells/EVIDENCE-arc8-still-OOM.txt) -> confirms NOT the ARC.
- WHY VU64 not VU32: fork-COW footprint ~linear in backend count; VU32(~40) fits 64GB, VU64(~74) exceeds
  -> OOM. Linux scales (real fork, MAP_SHARED shared_buffers stays shared not per-child COW).
- PG maps shared_buffers MAP_SHARED|MAP_ANONYMOUS; OSv fork SHOULD keep mmap_shared shared
  (clone_pt_level0 addr_is_shared). OPEN sub-Q (schema rebuild in progress): is the ~42GB (a) shared_buffers
  wrongly COW-duplicated per backend [OSv fork bug] or (b) genuine per-backend private growth. sb=2GB A/B pending.

## MEASURED RESULTS (earlier wake-path A/B detail, all REFUTED as cause)
- BASELINE (worker, VU64): WEDGE REPRODUCED. healthy ~60s (100-170k commit/15s, NVMe 30-77%, qemu
  1400-1900%) -> HARD CLIFF t=75s -> commit_delta=2, NVMe=0, ~66 backends WALWrite, never recovers.
- A/B OSV_ZIL_FLUSH_INLINE=1 (collapse the flush-completion INTERRUPT-taskq hops, prior-art 0040):
  STILL WEDGES identically. => lost wake NOT the taskq->backend hop. REFUTES hyp(d)-alone.
  cells/EVIDENCE-flushinline-STILL-WEDGES.txt
- A/B OSV_WAKE_IPI_ALWAYS=1 (always send wake IPI to non-idle-polling target; drop runqueue<=1
  suppression): STILL WEDGES identically. => lost wake NOT the send_wakeup_ipi guard.
  cells/EVIDENCE-wakeipi-always-STILL-WEDGES.txt
- SMOKING GUN (OSV_ZIL_WEDGE_PROBE=1): console at wedge:
    ZWEDGE LOST-WAKE slot=0 zcw=0x60085471e100 blocked_ms=418.3 zcw_done=1
  backend in untimed cv_wait(zcw_cv), zcw_done==1 (completion RAN + cv_broadcast), STILL ASLEEP 418ms.
  => LOST OSv condvar wakeup PROVEN (not upstream hang, that = zcw_done=0). cells/EVIDENCE-SMOKING-GUN-lost-wake.txt

## ROOT NOW LOCALIZED TO: the wait-morphing handoff on zcw_lock
  cv_broadcast(zcw_cv) -> condvar::wake_all -> mutex(zcw_lock)::send_lock(wr) -> mutex_exit(zcw_lock)::
  unlock -> other->wake() -> thread::wake_impl (waiting->waking CAS) -> enqueue + send_wakeup_ipi.
  The wake is dropped BEFORE send_wakeup_ipi (both send-side A/Bs refuted). Candidates:
  (i) condvar::wake_all clears the fifo + send_lock's onto zcw_lock, but the completion's mutex_exit
      (unlock) fails to hand the lock to the morphed wr (Bug-1 class RHO/handoff race), or
  (ii) thread::wake_impl CAS waiting->waking loses to a concurrent state transition.
  NEXT: instrument the morphing layer (send_lock got-lock vs queued; unlock popped-and-woke vs handoff;
  wr.woken() at the stuck waiter) to pin (i) vs (ii), then fix at root.
