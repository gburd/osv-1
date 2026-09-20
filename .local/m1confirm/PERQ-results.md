# OSv PERQ arm (OSV_BLK_MQ_COMPLETE=1) -- boot line: mode=per-queue num_queues=32
# The A/B is VALID: two DIFFERENT boot-mode lines captured (single vs per-queue), num_queues=32 both.

## VU16 (the decline point -- the decisive test)
r0 = 224507 (VOID: cold, post-recovery backlog drain) -- but see the util note below, it is telling
r1 = 69443   r2 = 70861   -> settled MEDIAN ~70152  (r3, r5 were HammerDB CLI init flakes = 0 NOPM,
                              PG healthy throughout; re-runs blocked by a stuck checkpointer, see below)

### Head-to-head at settled VU16 (3 SINGLE repeats vs 2 clean PERQ repeats)
    metric            SINGLE VU16      PERQ VU16
    NOPM median       67055            ~70152        (+4.6%, within run-to-run noise ~8-10%)
    NULL-wait         68-74%           77-78%        (STILL blocking to be woken after commit)
    LWLock/WALWrite   15-19%           11-13%
    NVMe %util        22-28%           25-27%        (device still ~3/4 IDLE in BOTH)
    qemu vCPU busy    ~11.8/32         ~12.3/32      (per-queue threads do NOT light up more CPU)
    total_busy_jiffies ~355k           ~371k         (near-identical completion work)

### VERDICT at settled VU16: PERQ ~= SINGLE. The per-queue completion fix does NOT move settled
### HammerDB NOPM and does NOT change the NULL-wait shape. The device sits ~74% idle in both arms.

## The one place PERQ clearly diverged: the COLD/backlog drain (r0)
PERQ VU16 r0 (cold, post-recovery): 224507 NOPM, NVMe %util MEDIAN 56% / MAX 89%, aqu-sz 1.55,
wkB/s 281MB/s (max 761MB/s). SINGLE never exceeded ~28% util / ~1.0 aqu-sz in ANY run.
=> The per-queue completion threads CAN drive the device 2-3x harder AND raise aggregate throughput
   WHEN THERE IS A DEEP BACKLOG of concurrent in-flight commits to drain (matches the +58% isolate).
   At settled 200wh/VU16 steady state, HammerDB does not keep enough commits in flight to fill the
   queues, so the extra completion threads have nothing to parallelize -> PERQ collapses back to SINGLE.

## Interpretation (stated straight, per the null-is-valid instruction)
The isolate win (+58% concurrent durable-write) REQUIRED a saturating concurrent-writer load. HammerDB
TPROC-C at 200wh/VU16 on this substrate is NOT WAL-completion-throughput-bound at steady state -- it is
NULL-wait bound (77% idle-stall, device 74% idle, ~12/32 vCPU busy). The backends are serialized on
something UPSTREAM of the block-completion path (the wakeup/scheduling after commit), not on the
completion drain itself. So #1509 helps the isolate and the cold-drain burst, but does NOT move the
steady-state HammerDB ceiling. This is the important null: the HammerDB gate is elsewhere, upstream of
completion. Consistent with the a2a3lever conclusion that the residual is WAL-commit *wakeup*
serialization, and #1509 addresses completion-drain, not the wakeup fan-out.

## No deadlock (the critical safety check on the lock-free req_done_q correction)
Across all PERQ runs, guest never wedged with 0-runnable. The 0-NOPM runs were HammerDB CLI flakes
(main.tcl line 146) with PG fully reachable (select 1 = 1) -- NOT the guest. top -H always showed
normal S/R thread mix, never all-asleep-0-runnable. The lock-free drain HELD under HammerDB load.

## VU32 (where SINGLE wedged)
r0 = 321412 (VOID: cold, %util MEDIAN 63% / MAX 96%, aqu-sz 4.96, 580MB/s -- device DRIVEN HARD in backlog drain)
r1 = 61965   r2 = 60757   -> settled MEDIAN ~61361   (r3=15966 degraded mid-run, util->0, recovered; PG healthy)
    wait: NULL 87.5-87.6%, WALWrite 6.4-6.8% | %util ~26% | qemu ~17.8/32 vCPU busy

### PERQ VU32 COMPLETED (~61k) where SINGLE VU32 WEDGED (0 NOPM x3, worker-start hang).
### CONFOUND, stated straight: SINGLE wedged via the fork/worker-start hang (NOT the dentry deadlock),
### which is NONDETERMINISTIC. a2a3lever's #1502 shape-fix run ALSO completed VU32 at ~62k WITHOUT
### #1509. So PERQ completing VU32 is NOT attributable to the completion fix -- it is the same ~61k
### ceiling, and PERQ simply did not hit the nondeterministic worker-start hang on these repeats.
### PERQ VU32 ~61k ~= a2a3lever shape-fix VU32 ~62k -> #1509 does not raise VU32 throughput either.

## Scaling shape, PERQ arm (settled medians)
    VU8  (not re-measured on PERQ; SINGLE VU8 was 103984 and #1509 is a no-op at low concurrency)
    VU16  ~70152   (SINGLE 67055)   -- essentially flat vs SINGLE
    VU32  ~61361   (SINGLE WEDGED)  -- still DECLINING VU16->VU32, NULL-wait rising 78%->87%
=> PERQ does NOT stop the decline. It declines VU16->VU32 just as SINGLE trends, and does not scale
   the way Linux does (159792->268921). The completion fix did not change the HammerDB scaling shape.
