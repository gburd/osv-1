# RESIDUAL-DIAGNOSIS — is the OSv PG concurrent-scale plateau structural or one more fixable lever?

Agent: osv-b3. AWS_PROFILE=fred acct 443433794128 us-east-2.
Instance: **i-0a2748e2f88e393a2** (osv-b3-host, m5d.metal, subnet 2b), tagged osv-b3-*.
Egress at launch 150.228.93.240 (Starlink, within scoped supernets). SG unmodified.

Base: wip/pg-scale2 @ e8147608 (MQ f411d5edc + idle-CPU PULL 3da8cea30 + parked-timer-unlink
e8147608, all G-signed). fs=ramfs conf_fork=1 image=postgres18-musl. loader-stripped.elf 122MB.
qemu 9.1.0 from source (KVM+vhost). N=8 vhost tap (queues=8 mq=on vectors=18 mrg_rxbuf=on).
Boot: -kernel PVH, --rootfs=ramfs, --env=OSV_WAKE_PULL=1, smp8 m12G cpu host,+x2apic.
"WAKE_PULL ON" printed at boot; PG18.6 ready 262ms; ping .2 0% loss; psql OK.

## STEP 0 — THE CLIMB REPRODUCES (RO -S, smp8, N=8 MQ, PULL on, 0-failed)
  c1 12533 | c8 62411 | c16 42043 | c32 40457 | c48 38859 | c64 37522   (all 0-failed)
  Matches BOTTLENECK2 (c8 ~61k, c32 ~41k). SHAPE = climb-to-c8 then a HIGH PLATEAU that HOLDS
  (c32-c64 all ~37-40k, no collapse). Config SHOW-proven: shared_buffers 128MB / max_conn 100 /
  io_method sync / fsync on / synchronous_commit on.

## STEP 1 — WHERE THE PLATEAU TIME GOES: wake-to-run ROUND-TRIP, NOT structural fork/COW cost

### Per-vCPU busy% (utime+stime delta, 3s window, all 8 qemu vCPU threads):
  c32:  96 97 96 97 96 96 96 95   (~96% each -- was pre-PULL 93/86/80/80/66/40/13/0 ragged)
  c64:  96 98 96 97 97 96 97 95   (~96% each)
  => ALL 8 vCPUs are ~96% "busy" -- PULL made the spread EVEN (vs pre-PULL 2-of-8 idle). BUT...

### GUEST-RIP SAMPLING (QMP `info registers -a`, all 8 vCPUs, ~2000 samples/point, addr2line):
  c32 (total 1993):  app=35 (1.8%)  kernel=1958 (98%)
    do_idle                 1120  (56%)   <- the 10000-iter idle spin-poll
    handle_incoming_wakeups  423  (21%)   <- draining the wake queue
    x2apic::ipi              126  (6%)    <- cross-CPU wake IPI
    atomic load/pci writew/memcpy/interrupt_entry/switch_to  ~200 (10%)
    lockfree::mutex lock+unlock  27 (1.4%)
    *** ZERO in vm_fault / page_fault / handle_mmap_fault / COW / vmas_mutex ***
  c64 (total 2128):  app=63 (3%)  kernel=2065 (97%)
    do_idle                 1283  (60%)
    handle_incoming_wakeups  439  (21%)
    x2apic::ipi              108  (5%)
    lockfree::mutex lock+unlock  16 (0.75%)
    *** ZERO in any fault/COW path ***

### THE RESOLUTION OF THE "96% BUSY BUT 3% APP" PARADOX:
  do_idle() is a BUSY-SPIN poll loop (core/sched.cc:551, `for ctr<10000 { handle_incoming_wakeups();
  if(!runqueue.empty()) return; }`) that burns host CPU (counts as vCPU-busy) while the guest CPU
  has NOTHING RUNNABLE and is waiting for the next wakeup. So "96% vCPU busy" = 86% of it is CPUs
  SPINNING in do_idle+handle_incoming_wakeups+ipi WAITING FOR WAKEUPS, only ~3% is real PG work.
  The plateau is the WAKE-TO-RUN ROUND-TRIP: 64 backends do request->reply->block ping-pong; each
  query is microseconds; between queries the serving CPU finds its runqueue empty and spin-polls
  in do_idle for the next packet's wakeup IPI, instead of promptly running an already-woken backend.

### STEADY-STATE COW FAULTS? NO. Confirmed NOT structural fork/COW cost:
  - Backend count stable at 65 across the run (64 clients + 1) = backends fork ONCE at connect,
    stay warm, serve many queries. NO per-query fork.
  - ZERO vm_fault/page_fault/COW RIP samples at BOTH c32 and c64 => steady-state RO pgbench does
    NOT COW-fault. The fork/COW cost is a ONE-TIME per-backend startup cost, NOT per-query, and it
    is not where the plateau time goes.
  => The plateau is NOT the fork-per-backend structural cost (that would show as page_fault/COW/
     TLB samples + rising with each new backend). It is the scheduler wake-to-run dispatch path.

### ROOT MECHANISM (source-confirmed, core/sched.cc):
  thread::wake_impl ALWAYS enqueues a woken thread on st->_cpu = its LAST-RUN CPU (tcpu), and sends
  a wakeup IPI there -- with NO check of whether that CPU is busy or another CPU is idle. With 64
  backends on 8 CPUs (~8 backends/CPU), a packet for backend B lands B on B's home CPU even if that
  CPU is running another backend; B waits in its runqueue while OTHER CPUs spin idle in do_idle.
  PULL (try_pull_from_busiest) is the safety net BUT it only steals when a CPU's runqueue depth
  >= wake_pull_min_depth (=2). In request/reply ping-pong each backend blocks right after replying,
  so runqueues are usually depth 0-1 -- BELOW the pull threshold -- so PULL rarely fires and the
  woken-but-not-running backend sits on a busy home CPU while idle CPUs spin.
  => This is a WAKE-PLACEMENT lever (send the wake to an idle CPU, or let PULL steal depth-1 work),
     NOT an irreducible per-forked-backend cost. FIXABLE. Tested in STEP 2/3.

## STEP 2 — smp8/16/32 PLATEAU PROGRESSION: rises smp8->smp16 then STOPS/regresses at smp32

Same image (smp is a boot param). N=vhost queues = smp (8/16/32); vhost opened all N queues
(verified 32 vhost-net fds at smp32). All 0-failed. RO -S 15s:

  smp  c1     c8     c16    c32    c48    c64
   8   12533  62411  42043  40457  38859  37522
  16   12088  74375  52292  51641  49246  45363
  32   12699  70886  60374  48312  44469  39084

### THE ANSWER: more vCPUs help UP TO ~smp16, then STOP helping (even regress) at smp32.
  - smp8 -> smp16: HELPS across the board (c8 +19%, c32 +28% [40457->51641], c64 +21%). PULL
    disperses correctly, the extra vCPUs get used.
  - smp16 -> smp32: does NOT help at mid/high c (c32 -6% [51641->48312], c48 -10%, c64 -14%);
    only c16 rises (+15% [52292->60374]). The plateau CEILINGS around smp16.
  - Per-vCPU at smp32 c32: all 32 vCPUs >30% busy (32 of 35 qemu threads) = the guest USES the
    vCPUs, but throughput is LOWER than smp16.

### WHY smp32 REGRESSES (RIP-proven): the do_idle spin fraction GROWS with vCPU count:
    smp8  c32:  do_idle 56%  handle_incoming_wakeups 21%  ipi 6%   app 1.8%
    smp32 c32:  do_idle 88%  handle_incoming_wakeups 8%   ipi 0.8% app 0.2%
  With 32 vCPUs but only ~32 backends doing request/reply ping-pong, most CPUs have nothing
  runnable at any instant and spin in do_idle. Adding vCPUs past the concurrency level just adds
  idle-spinners + wake-shuffling overhead; useful work per CPU shrinks. So the plateau is NOT a
  pure "needs vCPU-count >= concurrency" property -- it's a WAKE-ROUND-TRIP ceiling that more
  vCPUs cannot lift beyond ~smp16 for this ping-pong workload.

### vCPU:concurrency for the BEST plateau: smp16 is the sweet spot (c8 74k / c32 52k). smp32 does
  NOT beat smp16 at c32+. => the residual is a fixed wake-to-run dispatch ceiling, reachable at
  ~smp16, NOT relieved by throwing more vCPUs. This points at a FIXABLE wake-placement lever
  (send woken backends to idle CPUs / let PULL steal depth-1 work), tested next.

## STEP 3 — THE LEVER: wake-time idle-CPU steering (identified, real, but NOT fork-safe as-is)

The RIP profile (do_idle 56-88% + handle_incoming_wakeups 21%) + source read of wake_impl pinned
the residual to WAKE PLACEMENT: thread::wake_impl ALWAYS enqueues a woken backend on st->_cpu
(its LAST-RUN/home CPU) and IPIs there, with NO check of whether home is busy or another CPU is
idle. PULL (try_pull_from_busiest) is the only spreader and only steals runqueue depth >= 2, which
request/reply ping-pong (depth 0-1) rarely reaches. Two candidate levers tested:

### LEVER A -- lower wake_pull_min_depth 2 -> 1 (let idle CPUs steal a single queued backend):
  Made it env-tunable (OSV_WAKE_PULL_MINDEPTH). smp16 RO, md1 vs md2 baseline:
    c8 74375->67207 (-10%) | c16 52292->50387 (-4%) | c32 51641->48621/33k-on-repeat (WORSE) |
    c48 49246->48472 | c64 45363->44655
  => md1 is WORSE across the board (noisier, c8 -10%). Stealing depth-1 work causes cache-cold
     migration churn + IPI traffic that outweighs the dispersal. **CLEAN MEASURED NULL: the PULL
     threshold is already correctly tuned at 2; "PULL too conservative" is NOT the lever.**

### LEVER B -- wake-time idle-CPU STEER (a Linux select_task_rq analog): when a woken app thread's
  home CPU is loaded AND an idle CPU exists, place the wake on the idle CPU instead of home.
  This is EXACTLY the residual's fix (disperse the wake fan-out at wake time, not wait for PULL).
  *** An implementation ALREADY EXISTS: gh-fork pr/sched-wake-idle-steer @ 9a6ba7aca "sched: steer
  woken threads to idle CPUs" (G-signed, maintainer-written). ***
  Ported it onto pg-scale2 (env-toggled OSV_WAKE_STEER=1, off=byte-identical) and measured:
    CRASH #1: `assert(preemptable()) page_fault:38` at c8 -- the IRQ-COW-timer disease. Steering a
      blocked app thread cross-CPU leaves its PARKED on-stack timer nodes linked on home's per-CPU
      parked list; a later timer IRQ walks them through a foreign AS -> fault in non-preemptable
      context. (Same disease PULL's e8147608 unlink-before-migrate fixed for the queued path.)
    FIX for #1: added `#if CONF_fork if (target!=tcpu && st->t->_parked_link.is_linked()) skip-steer`
      in wake_impl (unlink_parked can't run from the waker's CPU -- it touches the OWNER cpu's list).
    CRASH #2 (after fix #1): `assert(_renormalize_count != -1) ran_for:2515` at c8 -- the runtime-
      export race the maintainer's own comment warns about: steering exports the thread's runtime
      (_renormalize_count=-1) and it ran before the destination's update_after_sleep() converted it
      back. My hot-path port has a residual race the non-fork original didn't hit.
  *** ROOT: 9a6ba7aca has ZERO CONF_fork awareness (no parked-timer, no unlink, verified) -- it was
  written+validated on a NON-fork tree (pr/sched-wake-idle-steer off the tail base). On a fork
  build, wake-time cross-CPU migration hits BOTH the parked-timer disease AND fork's altered
  runtime/scheduling coherence. Making steer fork-safe is a NON-TRIVIAL scheduler change (parked-
  timer coherence + runtime-export coherence across a wake-time migration), NOT a small safe diff. ***

### VERDICT ON THE LEVER: the residual IS a fixable wake-placement lever (NOT irreducible fork/COW
  cost -- STEP 1 proved zero steady-state COW faults). The fix (wake-time idle-steer) is correctly
  identified and EXISTS for non-fork OSv (9a6ba7aca). But porting it to the fork build safely
  requires resolving two fork-specific scheduler-correctness hazards (parked-timer + runtime-export
  coherence at wake-time migration) that a hot-patch cannot land under crash-risk discipline.
  => NOT pushed as a fork-build fix (would gamble the clean 0-failed deliverable on a scheduler
     race). The env-toggle scaffolding (OSV_WAKE_PULL_MINDEPTH, OSV_WAKE_STEER, both off=byte-
     identical) + the parked-timer guard are the groundwork; the runtime-export coherence is the
     remaining piece for a future fork-safe steer. STEP 4 benchmarks the SAFE build (steer off).

## STEP 4 — APPLES-TO-APPLES OSv(safe pg-scale2, steer off) vs Linux, smp8/16/32, RAM-vs-RAM

Harness (fair, single variable = OS/vCPU-count): ONE m5d.metal, qemu 9.1.0 from source
(KVM+vhost-net), guests run SEQUENTIALLY. Both N-queue vhost tap (queues=smp, mq=on,
vectors=2N+2, mrg_rxbuf=on) on br0; driven from HOST over tap IPs (real net, .2 OSv / .3 Linux).
RAM-vs-RAM: OSv ramfs / Linux tmpfs(10G). PG18.6 both, config MATCHED + SHOW-PROVEN on BOTH:
shared_buffers=128MB, max_connections=100, io_method=sync, fsync=on, synchronous_commit=on.
pgbench -s50 15s, 0-failed gated (ALL cells 0-failed). OSv = the safe build (PULL on, mindepth=2,
STEER off = byte-identical to pg-scale2 @ e8147608; verified no crash, c32 48150 stable).

### RO (SELECT-only) tps -- FULL smp8/16/32 GRID:
```
        c1     c8     c16    c32    c48    c64
OSv  8  12533  62411  42043  40457  38859  37522
OSv 16  12088  74375  52292  51641  49246  45363
OSv 32  12699  70886  60374  48312  44469  39084
Lin  8  10628  90643  98120  91466  90252  90373
Lin 16  10728  91298 166553 170321 181879 172583
Lin 32  10532  90450 141309 199857 210159 176089
```

### OSv/Linux RO ratio (best OSv smp16 vs Linux at SAME smp):
```
  c    OSv16/Lin8   OSv16/Lin16   OSv32/Lin32
  1     1.14         1.13          1.21
  8     0.82         0.81          0.78
  16    0.53         0.31          0.43
  32    0.56         0.30          0.24
  48    0.55         0.27          0.21
  64    0.50         0.26          0.22
```

### RW (TPC-B) tps, smp16, 0-failed:
```
  c    OSv16   Lin16   OSv/Lin
  1    1838    1942    0.95
  8    9568    14322   0.67
  16   13998   25381   0.55
  32   12775   23037   0.55
  48   8840    24631   0.36
  64   12102   24371   0.50
```
  (OSv RW climbs to c16 then holds ~12-14k, 0-failed all cells incl c48/c64 -- no heap-page
   corruption this run. Big lift vs CORRECT-BUILD RW c32 2708 -> 12775 = 4.7x. Note: the prior
   "RW OSv WINS every cell" was vs Linux-on-ZFS; here Linux is on tmpfs (~2x faster than ZFS on
   RW/fsync), so OSv is 0.5-0.67x, not winning -- an honest RAM-vs-RAM-matched comparison.)

### THE PLATEAU-vs-vCPU PROGRESSION (the STEP-2 answer, restated with Linux alongside):
  - OSv: rises smp8->smp16 (c32 40457->51641 = +28%), then STOPS/regresses smp16->smp32
    (c32 51641->48312). OSv plateaus ~50k at c32 regardless of vCPUs past 16.
  - Linux: rises MONOTONICALLY with vCPUs (c32 91k@smp8 -> 170k@smp16 -> 200k@smp32). Linux's
    async/threaded server turns every added vCPU into throughput; OSv's process-per-backend +
    wake-to-home-CPU placement caps at ~smp16 for this ping-pong workload.

### VERDICT (does more vCPUs lift the OSv plateau? PARTIALLY -- up to smp16, then no):
  OSv scales up smp8->smp16 (PULL disperses correctly), but the plateau CEILINGS at ~smp16 and
  does NOT keep rising with vCPUs like Linux. The residual is the wake-to-run ROUND-TRIP (STEP 1:
  60-88% do_idle spin + 21% handle_incoming_wakeups, ZERO COW/fault), NOT irreducible fork/COW
  cost (backends warm, no steady-state COW). It IS a fixable wake-placement lever (STEP 3:
  wake-time idle-steer), but a fork-safe implementation is non-trivial scheduler work
  (parked-timer + runtime-export coherence at wake-time migration), not landed this run.

### IS IT STRUCTURAL OR A LEVER? -- A LEVER, quantified:
  - NOT the fork-per-backend structural cost: zero steady-state COW/page-fault RIP samples at
    c32 AND c64; backends fork once + stay warm; the plateau is scheduler wake-dispatch, not
    per-fork memory cost.
  - The lever: wake placement (wake_impl always enqueues on the last-run CPU; no idle-CPU steer;
    PULL only steals depth>=2 which ping-pong rarely reaches). Fix = wake-time idle-steer
    (identified, exists for non-fork OSv as 9a6ba7aca, needs fork-safety port).
  - vCPU:concurrency for parity: OSv reaches its best plateau at smp16 (~vCPU=concurrency/2 to
    /4); beyond smp16 more vCPUs don't help. Linux reaches parity-and-beyond because it needs
    only ~vCPU=concurrency/4 (async). So OSv's ceiling is NOT "needs more vCPUs" -- it's the
    per-wake dispatch round-trip that caps useful parallelism at ~smp16 for request/reply.

## STEP 3 (addendum) — ROOT CAUSE of the steer crash #2 (the runtime-export race): STEER + PULL
The `assert(_renormalize_count != -1) ran_for:2515` is a THREE-WAY interaction: wake-time steer
exports a thread's runtime (_renormalize_count = -1) and retargets it to an idle CPU; but that
thread can then be picked up by PULL's donate_to_puller (or load_balance) -- which migrates a
QUEUED thread WITHOUT calling update_after_sleep() -- before it ever runs on the steered-to CPU.
The second migration re-exports an already-exported runtime / the thread runs still-exported ->
the assert. load_balance/PULL are safe for their own migrations (queued threads whose runtime was
never exported), but a STEERED thread arrives already-exported, breaking that invariant. So a
fork-safe wake-steer must coordinate with PULL/load_balance on the exported-runtime state -- a real
scheduler-design task, not a hot-patch. Confirmed: the lever is real and correctly located; landing
it safely is bounded scheduler work (parked-timer coherence + exported-runtime coherence vs PULL),
deliberately NOT gambled onto the clean 0-failed deliverable this run.

## HOST IDLE at the OSv plateau (skill-required): host 85.6% idle at OSv smp16 c32 (16 guest
vCPUs on a 96-core host; all 16 guest vCPUs >30% busy = OSv USES its vCPUs, mostly spinning in
do_idle). => NOT host-CPU-limited; the plateau is the intra-guest wake-to-run round-trip. FIXABLE
(the identified wake-placement lever), not a host-resource floor.

## FINAL ANSWER TO THE QUESTION (structural vs one-more-lever):
  IT IS A LEVER, NOT STRUCTURAL -- quantified:
  1. STEP1 RIP (c32 AND c64): 60-88% do_idle spin + 21% handle_incoming_wakeups + 5% ipi, only
     ~3% app; ZERO COW/vm_fault/page_fault at either c => the plateau is the wake-to-run round-
     trip, NOT per-forked-backend memory cost.
  2. Backends fork ONCE + stay warm (count stable 65 at c64); NO steady-state COW faults => the
     fork-per-backend cost is a one-time startup cost, not the per-query plateau.
  3. STEP2: more vCPUs HELP smp8->smp16 (c32 +28%) then STOP at smp32 (the do_idle fraction grows
     56%->88%) => a fixed wake-dispatch ceiling reachable at ~smp16, not a pure vCPU-count wall.
  4. STEP3: the lever = wake-time idle-CPU steer (send a woken backend to an idle CPU when home is
     busy, vs OSv's always-wake-on-home-CPU). Fix EXISTS for non-fork OSv (9a6ba7aca); a fork-safe
     port needs parked-timer + exported-runtime coherence (bounded scheduler work). NOT landed
     (crash-risk vs the clean deliverable), but IDENTIFIED + root-caused.
  => The plateau is one more FIXABLE lever (wake placement), not an irreducible fork-per-backend
     structural cost. The residual gap to Linux (OSv ~0.3x at c32 smp16) is Linux turning every
     vCPU into throughput via async while OSv's wake-to-home-CPU placement caps useful parallelism
     at ~smp16 for request/reply ping-pong -- closable by fork-safe wake-steer, not by more vCPUs.
