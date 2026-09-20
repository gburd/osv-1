# Fork-safe wake-time idle-CPU steer — STEP 1 design + validation + benchmark

Agent: osv-steer. AWS_PROFILE=fred acct 443433794128 us-east-2.
Instance: **i-0d624feb13012b726** (osv-steer-host, m5d.metal, subnet 2b), tagged osv-steer-*.
Public IP at launch 3.143.224.17. Egress 150.228.93.240 (Starlink, in scoped supernets). SG unmodified.

Base: wip/pg-scale2 @ e8147608 (MQ + idle-CPU PULL + parked-timer-unlink). New branch
wip/pg-scale3-steer @ 2fe392416 "sched: fork-safe wake-time idle-CPU steering".

## STEP 1 — the STEER+PULL exported-runtime coherence (design, source-proven)

### The runtime invariant (core/sched.cc, verified by reading the code)
A thread's CPU-local runtime `_Rtt` is measured against SOME cpu's normalization
scale `c`; `_renormalize_count` records which renormalization epoch that scale is in.
  - `export_runtime()` divides `_Rtt` by the CURRENT cpu's `c` and sets
    `_renormalize_count = -1` (the "exported / global" sentinel).
  - `export_runtime(from)` (added) divides by `from->c` instead — used when the thread
    is NOT running on the current cpu (a blocked thread being steered off its home cpu:
    its runtime is in home's scale, not the waker's).
  - `update_after_sleep()` (run on the DESTINATION cpu in handle_incoming_wakeups)
    converts a `-1` back by multiplying by the destination's `c`, then sets
    `_renormalize_count = dst->renormalize_count`.
  - `ran_for()` asserts `_renormalize_count != -1` — **a thread must never RUN while
    exported.** This is the assert crash #2 tripped (`ran_for:2515`).

### What a blocked thread's runtime state actually is (proven, not assumed)
When a thread blocks, `reschedule_from_interrupt` calls `ran_for(interval)` (which
asserts NOT exported) then `hysteresis_run_stop()`. So a **blocked thread is NOT
exported**: `_renormalize_count >= 0`, `_Rtt` in its home cpu's `c` scale. Therefore
`export_runtime(tcpu)` at wake time is the correct one-time conversion, and the
destination's single `update_after_sleep()` converts it back. **The isolated steer
(no PULL) is coherent** — this was verified against pin()'s status::waking migration
case (the proven cross-cpu-migrate-a-waking-thread envelope), which does the identical
export + retarget + tls-var write.

### The two crashes and their true root causes
CRASH #1 `assert(preemptable) page_fault` = the IRQ-COW-timer disease. A blocked app
  thread's on-stack timer nodes are PARKED on its HOME cpu's per-CPU parked list
  (park_timers runs on every app-thread switch-out). The other migration paths
  (load_balance, donate_to_puller, pin) call `cpu::unlink_parked()` before moving such
  a thread — but they all run ON the thread's OWNING cpu, where mutating that cpu's
  parked list + re-arming its park timer is safe. `wake_impl` runs on the WAKER's cpu
  (neither home nor target), so it CANNOT safely unlink from home's list
  (`unlink_parked` reaches into `owner->parked_threads` + `owner->rearm_park_timer()`
  with no owner lock).

CRASH #2 `assert(_renormalize_count != -1) ran_for` = the STEER+PULL exported-runtime
  race. Between the steer's `export_runtime` and the destination's
  `update_after_sleep`, the thread sits in `target->incoming_wakeups` as
  `status::waking`. That state alone is PULL-safe (donate_to_puller/load_balance only
  read the `runqueue`, not incoming_wakeups). BUT once it lands and is enqueued
  (`status::queued`), if the migration-lock isn't held, a second migration path could
  in principle re-export or let it run mid-conversion. The invariant the fix must
  preserve: **exactly one export is matched by exactly one update_after_sleep on the
  destination, with no intervening re-migration.**

### FIX CHOSEN (the cleanest correct one — combines the task's (b) + (c))
Both `donate_to_puller` and `load_balance` already select their migration victim via
`migratable()` == `_migration_lock_counter == 0`. So the seam is closed BY
CONSTRUCTION with zero new machinery:
  - Fix #1 (parked-timer): `steer_to_idle_cpu` REFUSES to steer a thread whose timers
    are parked (`_timers_parked || _parked_link.is_linked()`). It stays on home (timers
    valid) and is dispersed later by an owner-side migration. `#if CONF_fork`. This is a
    placement decision, not a correctness compromise.
  - Fix #2 (STEER+PULL runtime race): the steer path bumps the thread's
    `_migration_lock_counter` and sets `_steered_pending` before the export+retarget;
    the destination's `handle_incoming_wakeups` clears both IMMEDIATELY after
    `update_after_sleep()` and before `enqueue()`. So the steered thread is
    PULL/balance-INELIGIBLE for exactly the export window and no longer. `#if CONF_fork`
    (a non-fork build has no idle-pull path to race). steer_to_idle_cpu only steers a
    thread whose lock was already 0, so the bump/clear is balanced.
Why not the task's (a) "let the normal wake path do the single export": the normal wake
  path enqueues on HOME, not on an idle cpu — there is no "normal path" that both places
  the thread on the idle cpu AND does the single export/update; the export must happen
  where the retarget happens (the waker), and the update where it lands (the target).
  Reusing pin()'s full envelope was rejected because pin's suspend_timers/unlink_parked
  MUST run on the owning cpu (same cross-cpu hazard as crash #1); for a NON-parked
  steer candidate there are no per-cpu timers to suspend, so export+retarget+push +
  destination-update is the complete correct migration once parked threads are excluded.

### The code (branch wip/pg-scale3-steer @ 2fe392416, off pg-scale2 @ e8147608)
  - conf/kconfig/threads: `config sched_wake_idle_steer` (def_bool y, compiled-in).
  - core/sched.cc: `wake_steer_enabled` runtime toggle (env OSV_WAKE_STEER=1, prints
    "WAKE_STEER ON/off"); `steer_to_idle_cpu(t, home)` (app-only, not-current,
    migratable, #if CONF_fork not-parked, home loaded, first idle cpu wins);
    `wake_impl(st, mask, may_steer)` steer path (bump migration lock + _steered_pending
    #if CONF_fork, export_runtime(tcpu), retarget, push to target); wake() passes
    may_steer=true (the ONLY caller that does; all IRQ/kernel wake paths default false);
    handle_incoming_wakeups clears _steered_pending + drops the lock after
    update_after_sleep; export_runtime(cpu* from) definition.
  - include/osv/sched.hh: wake_impl 3rd param, export_runtime(cpu*), `_steered_pending`
    field (#if CONF_fork).
  - conf_fork=0 byte-identical: every fork-specific guard is #if CONF_fork; the steer
    itself is #if CONF_sched_wake_idle_steer + runtime-gated off by default.

## STEP 2 — validation (PENDING — building on the box)

### STEP 2a (crash gate) — PASS. Built conf_fork=1 fs=ramfs image=tests, steer compiled in
(config sched_wake_idle_steer). Booted -k PVH under qemu 8.1.3 (fedora:39 container, KVM
passthrough) with --env=OSV_WAKE_PULL=1 --env=OSV_WAKE_STEER=1. Both print at boot:
"WAKE_PULL ON / WAKE_STEER ON". Ran the fork+timer+migration crash battery at smp8 AND smp16:
  tst-fork-irq-cow (crash #1's own regression test), tst-fork, tst-fork-deep, tst-fork-cow,
  tst-fork-preempt (migration-heavy).
RESULT: 10/10 runs (5 tests x smp8/16) booted STEER-ON and completed **0 failures, 0 asserts,
  0 crashes**. NO assert(preemptable) (crash #1), NO assert(_renormalize_count != -1) (crash #2),
  NO page fault, NO abort/panic anywhere in the log. The parked-timer guard + migration-lock
  exclusion hold under the isolated fork+timer+migration hazard at smp8 and smp16.
### STEP 2b/c (real PG serving + sustained pgbench under load) — building musl PG18 (the load
  proof the diagnosis requires; the runtime race showed up UNDER LOAD).

### STEP 2c ATTEMPT 1 (sustained PG load) — CRASHES. Two distinct crashes under real pgbench:
  - Run 1 (c32 T60 steer-ON): `assertion failed: _renormalize_count != -1 (ran_for:2590)` = crash #2
    (STEER+PULL exported-runtime race) STILL trips despite the migration-lock exclusion.
  - Instrumented (debug STEERBUG dump in reschedule_from_interrupt before ran_for): the REAL
    culprit is an APP thread (is_app=1), steered_pending=0 at fault time, and the actual fault is
    `assert(preemptable()) arch/x64/mmu.cc page_fault:38` = crash #1 (the IRQ-COW-timer disease),
    on curcpu=5.

### ROOT CAUSE (the crux, now understood correctly):
  wake_impl runs on the WAKER's cpu. A blocked app thread's timers live on its HOME cpu:
    - ACTIVE timers on home's per-CPU timer list (relocated by suspend_timers, which operates on
      cpu::current()->timers = the caller's cpu),
    - and/or PARKED on home's parked list (relocated by unlink_parked, on the owning cpu).
  The proven migration paths (pin/load_balance/donate_to_puller) ALL run ON the thread's source
  (home) cpu -- pin via a helper thread pinned to the source cpu, load_balance/donate via an IPI
  serviced on the source cpu -- precisely so suspend_timers()/unlink_parked() touch the RIGHT
  cpu's lists. A wake-time steer from a FOREIGN (waker) cpu fundamentally CANNOT safely relocate
  the thread's timer state: suspend_timers on the waker touches the waker's list, not home's;
  unlink_parked reaches into home's list without home's lock. My parked-guard only covered the
  PARKED case; a non-parked blocked thread with ACTIVE home-cpu timers still faults (crash #1),
  and the runtime race (crash #2) is a separate hazard on top.
  => A correct wake-time steer must do the migration ON the home cpu (like the proven paths),
     not on the waker. Redesigning: STEP 1b below.

## STEP 1b — THE FIX THAT WORKS (root-caused via on-box instrumented reproduction)
The migration-lock exclusion (attempt 1) did NOT close the race. Instrumenting
reschedule_from_interrupt (dump the thread state whenever ran_for sees _renormalize_count==-1
with _Rtt!=0) caught the culprit under sustained pgbench: an APP thread (is_app=1) with
steered_pending=1, miglock=1 -- i.e. a STEERED thread that RAN while still exported, blocked in
sem_wait -> thread::wait() -> reschedule_from_interrupt -> ran_for (backtrace confirmed).

TRUE ROOT CAUSE (the "still-running" window): a thread that called prepare_wait() sets itself
status::waiting WHILE STILL EXECUTING on its home cpu (before cpu::schedule() actually
deschedules it). A waker that wins the waiting->waking CAS in that window would steer a thread
that is concurrently RUNNING on home. The original steer's `if (t == thread::current()) return
home` only checks the WAKER's current thread -- it does NOT catch a thread that is current on a
DIFFERENT (home) cpu. So a running-on-home thread got exported from the waker's cpu, and home's
reschedule_from_interrupt then charged it (ran_for) while it was exported -> assert.

FIX: steer_to_idle_cpu also refuses to steer a thread that is its home cpu's currently-running
thread, read via `t == t->remote_thread_local_var(s_current)` (t's percpu context is still home's
since we have not retargeted it). Combined with:
  - only steer app threads with NO timer state (has_active_timers/timers_suspended/timers_parked
    all false) -- a foreign-cpu wake_impl cannot relocate home-cpu timers (fixes crash #1), and
  - hold the migration lock + _steered_pending from the steer through the thread's FIRST RUN on
    the target (cleared in reschedule_from_interrupt when it is selected), keeping PULL/balance
    off it across the whole export->convert->run window (belt-and-suspenders for crash #2).

## STEP 2 VALIDATION — 0-crash 0-failed under sustained load (smp8)
  - STEP 2a (fork+timer crash battery, tst-fork-irq-cow/fork/deep/cow/preempt at smp8 AND smp16,
    STEER=1+PULL=1): 10/10 runs 0 failures, 0 asserts. (banked above)
  - STEP 2b (8 concurrent psql, --rootfs=ramfs fixes the /dev/urandom cancel-key issue = BUG A):
    8 distinct backend pids, 0-crash.
  - STEP 2c (sustained pgbench RO, real vhost net, 172.20.0.2, PG18.4 musl server on matched 18.4
    initdb data, config SHOW-able):
      c32 T90 STEER ON: 0 failed, tps 40862, ZERO OSv scheduler asserts, no reboot.
      c64 T90 STEER ON: 0 failed, tps 37853, ZERO OSv scheduler asserts, no reboot.
      c64 T90 STEER OFF: 0 failed, tps 38062 (isolation control).
  - The scheduler race is FIXED: grep for renormalize/preemptable/page_fault/Assertion = 0 across
    all sustained steer-ON runs. The `pg_attribute catalog is missing OID 2671/2964` messages are
    a PRE-EXISTING PG fork-catalog-cache artifact under a c64 connection storm (present steer-OFF
    too, transient, non-fatal to steady state -- lands on some setup connections); it is the
    documented shared-anon-catalog fork coherence item, NOT the steer and NOT the scheduler.

## STEP 3 — PUSHED G-signed (durable, before the full benchmark)
gh-fork wip/pg-scale3 @ fa93fab3d "sched: fork-safe wake-time idle-CPU steering", based on
pg-scale2 @ e8147608. %G? = G (ssh-signed greg@burd.me). Leak-scan clean: no acct-ids / SG /
subnet / AMI / IPs / m5d / HammerDB / ponytail / campaign / em-dashes; all edits to existing
files (no new copyright header needed); commit body genericized (no pgbench/testbed specifics).
Clean commit (debug removed) re-validated: c32 T90 steer-ON 0-failed tps 40750, 0 scheduler
asserts, no reboot; builds both image=tests and image=pg18-fork conf_fork=1.

## ============================================================================
## SESSION-END STATE (honest, banked on shutdown)
## ============================================================================
## SHIPPED: gh-fork wip/pg-scale3 @ fa93fab3d "sched: fork-safe wake-time idle-CPU steering"
##   (based on pg-scale2 @ e8147608), G-signed (%G?=G), leak-clean, conf_fork=0 byte-identical.
##
## VALIDATION STATE OF fa93fab3d (be honest):
##   - STEP 2a crash battery (tst-fork-irq-cow/fork/deep/cow/preempt, smp8 AND smp16, STEER=1):
##     10/10 runs 0 failures, 0 asserts. PASS.
##   - STEP 2b: 8 concurrent psql -> 8 distinct backend pids, 0-crash. PASS (needs --rootfs=ramfs
##     for BUG A /dev/urandom cancel-key).
##   - STEP 2c sustained PG load (real vhost net, PG18.4 musl on matched 18.4 initdb):
##       * c32 T90 STEER ON: 0-failed, tps ~40750-40862, ZERO OSv scheduler asserts, no reboot.
##         REPRODUCED MULTIPLE TIMES on the clean commit (debug removed). SOLID.
##       * c64 T90 STEER ON: 0-failed, tps ~37853, ZERO OSv scheduler asserts, no reboot (round1).
##   => THE SCHEDULER RACE IS FIXED for the validated envelope: the s_current "still-running-on-
##      home" guard + the no-timer-state guard + the hold-miglock-until-first-run were the three
##      pieces. Before those, sustained c32 load tripped BOTH assert(preemptable) page_fault:38
##      (crash #1, timer) AND assert(_renormalize_count != -1) ran_for (crash #2, runtime) within
##      ~60s. After: 0 asserts across repeated c32/c64 T90 sustained runs.
##
## HONEST CAVEAT / NOT-FULLY-CLOSED (the reason a final signed-off benchmark did NOT complete):
##   A PRE-EXISTING PostgreSQL fork-catalog-cache artifact -- "pg_attribute catalog is missing N
##   attribute(s) for relation OID 2671/2964" -- appears under a HIGH-CONCURRENCY CONNECTION STORM
##   (many short reconnects, e.g. a multi-round c-sweep or a heavy pgbench -i in-guest). It occurs
##   with STEER OFF too (isolation-confirmed: c64 T90 steer-OFF also logged it yet ran 0-failed),
##   so it is NOT the steer and NOT the scheduler -- it is the documented shared-anon-catalog fork
##   coherence item (LESSONS-pg-scale.md item 5). BUT once triggered it is STICKY for that boot and
##   poisons the DB (subsequent connects, even c1, FATAL). This blocked a clean multi-round steer-
##   ON-vs-OFF-vs-Linux sweep: the sweep's own reconnect storm corrupts the catalog before all
##   c-values complete. A single sustained run per c-value on a PRISTINE boot is clean; the
##   repeated-reconnect sweep is not.
##   => WORKAROUND IN PROGRESS when stopped: bake the pgbench dataset into the host data dir at
##      build time (start the glibc PGDG 18.4 server locally on /b/.local/pg18/data, pgbench -i -s50,
##      clean stop, bake) so the guest boots with the dataset already present and NEVER runs the
##      storm-inducing in-guest init. That last bake command was mid-flight at stop (the reinit
##      REINIT_OK printed; the local-server pgbench -i had not confirmed BAKED yet).
##
## STEP 4 BENCHMARK: NOT COMPLETED. The steer-ON-vs-OFF-vs-Linux RO c1-c64 sweep + RIP-at-c32 +
##   per-CPU idle% was NOT run to a 0-failed 3-round median because of the catalog-storm blocker
##   above. The ONLY clean throughput data points captured (single sustained runs, steer-ON, smp8):
##     c8 ~52004 tps, c32 ~40750 tps, c64 ~37853 tps (all 0-failed) -- these are single-run, NOT
##     the 3-round-median gated sweep, and there is NO matched steer-OFF or Linux column yet, so
##     they are NOT a defensible parity/delta answer. The KEY QUESTION (does RO c16-c64 CLIMB with
##     steer-ON vs the steer-OFF plateau) is UNANSWERED by a fair matched benchmark this session.
##   NOTE: c32 steer-ON single-run ~40750 is in the SAME ballpark as the steer-OFF pg-scale2
##     smp8 c32 baseline (~40457 from RESIDUAL-DIAGNOSIS) -- so there is NO obvious steer win
##     visible in the uncontrolled single-run numbers, but this is NOT a controlled A/B and must
##     not be read as "steer does nothing." A proper matched sweep (dataset pre-baked to dodge the
##     catalog storm) is required to answer the climb question.
##
## => NEXT SESSION (resume plan):
##   1. Finish baking the pgbench dataset into /b/.local/pg18/data via the local PGDG 18.4 server
##      (start on port 5433, pgbench -i -s50, pg_ctl -w stop, then build image=pg18-fork so the
##      guest boots with tables present). This dodges the in-guest catalog-storm entirely.
##   2. Run the matched sweep: OSv steer-ON vs steer-OFF (env OSV_WAKE_STEER=1/0, same image) at
##      smp8 AND smp16, RO -S c1/8/16/32/48/64, single sustained T30+ run per c-value (avoid the
##      reconnect storm), 0-failed gated, on a fresh boot per config. Then Linux PG18 tmpfs same
##      sweep. RIP-sample + per-CPU idle% at c32 for steer-ON (did do_idle-spin drop vs the
##      steer-OFF 56-88%?). THAT answers the climb question.
##   3. Separately worth fixing on its own merit: the PG fork-catalog-cache corruption under a
##      connection storm (shared-anon catalog coherence) -- it gates any high-reconnect workload.
##
## BUILD ENV (reusable next session): box was m5d.metal AL2023; build in fedora:39 container image
##   osv-builder:f39 (deps baked), run in osv-runner:f39 (+ qemu 8.1.3, KVM passthrough), driver
##   pgdriver:18 (PGDG 18 client), initdb helper pginit:184 (PGDG 18.4). Repo cloned from gh-fork
##   wip/pg-scale2 + steer patch; kbuild/acpica/musl submodules need explicit --init --force (the
##   apps submodule commit 57c60798 is NOT public -- ship apps tree + PG install as tarballs from
##   .local/pg18 and .local/worktrees/fork-arena/apps). PG image needs share/postgresql/ (BKI +
##   timezone from system zoneinfo) and a MATCHED-minor (18.4) initdb data dir; boot --rootfs=ramfs.

## ============================================================================
## STEER2 RUN (agent osv-steer2, i-0fdbfb6f7cab72f84 m5d.metal) — STEP 4 a2a
## THE HEADLINE ANSWER: the fork-safe wake-steer VALIDATES (0-crash) but does
## NOT climb — it is a measured NULL/REGRESSION for RO throughput.
## ============================================================================
## Build wip/pg-scale3 @ fa93fab3d (steer, fork-safe), conf_fork=1 fs=ramfs.
## smp8/16, N=queue vhost, RAM-vs-RAM, config SHOW-proven matched (both io=sync,
## sb=128MB, mc=100, fsync=on, sync_commit=on). pgbench -s50, 3-round median,
## 0-failed gated (ALL cells 0-failed). Driver = postgres:18 (pgbench 18.6).
##
## RO (-S) median tps — STEER ON vs OFF, same build, only OSV_WAKE_STEER differs:
##          c1     c8     c16    c32    c48    c64
## smp8 ON  12821  36221  28371  29465  28132  26951
## smp8 OFF 12421  58188  42067  41081  28449  27654
## smp16 ON 12382  73068  51589  49482  31985  30818
## smp16 OFF (running)
##
## RW (TPC-B) median tps:
##          c1    c8    c16   c32   c48   c64
## smp8 ON  1737  4358  3938  3653  3447  (c64 n/a)
## smp8 OFF 1820  4488  4053  3695  3501  3196
## smp16 ON 1705  6047  4610  4297  3841  3600
##
## VERDICT (STEER, smp8): steer-ON is WORSE than steer-OFF for RO at every mid
## c-value (c8 36221 vs 58188 = -38%; c16 -33%; c32 -28%). RW ~flat (RW backends
## arm WaitLatch timers = has_timer_state -> not steer-eligible, so steer barely
## fires on RW). => the wake-time idle-CPU steer does NOT lift the RO plateau;
## it HURTS it at smp8. The migration/cache-cold cost + guard-scan cost of
## steering each woken backend to a cold idle cpu outweighs the dispersal
## benefit for this request/reply ping-pong — same result class as LEVER A
## (lower pull-threshold, also measured WORSE in RESIDUAL-DIAGNOSIS). The steer
## is correctly IMPLEMENTED + fork-SAFE (0-crash under sustained load), but it is
## NOT the parity lever: it is a measured NULL/regression, not a climb.
