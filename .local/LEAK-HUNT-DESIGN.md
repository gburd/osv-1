# OSv forked-backend / connection-churn TEARDOWN LEAK hunt: design (the real M1 bug)

## The bug (measured symptom, mechanism hypothesized)
Within one guest boot, sequential HammerDB cells degrade 169k->43k->0->0->0->0 NOPM (progressive wedge
to hard zero). Fresh-boot VU32 = 215k (healthy). Linux does NOT degrade (r1 158k -> stays 159k). Reboot
is the only reset. => a resource LEAK/exhaustion accumulating across forked-backend churn, OSv-specific.

## Local source recon done (narrows the candidates):
- libc/process/fork.cc: the reaper DOES erase its bookkeeping maps (g_as_pid, g_pid_as,
  g_child_fd_tables, g_child_sigtables all .erase on reap) - so the OBVIOUS map leak is NOT it.
- release_fd_table drops fd refs + frees the table; the AS/sigtable are freed. So the leak is DEEPER:
  candidates = the AS physical pages / thread stacks / fork-arena COW pages not returned, ZFS/dentry
  state per connection, or the reaper not running on EVERY exit path (abnormal vs clean).

## THE REPRO (cheaper than HammerDB - use this):
A connect/disconnect churn loop, NOT full HammerDB: open N (e.g. 32) PG connections, each runs a trivial
txn (SELECT 1 or a tiny insert), close all N, repeat M rounds (e.g. 50-200). Each round forks+reaps N
backends. This isolates the fork/reap teardown path with far less noise and cost than TPROC-C.

## PER-ROUND INSTRUMENTATION (sample between rounds from the guest - whatever GROWS monotonically is the leak):
  - OSv thread count (sched::thread count / a thread-list walk) - forked-backend threads not reaped?
  - free memory + ARC size + memory::stats::free() - and global_l2._nr (the earlier 26.9GiB-free-but-
    nr=0 wedge signature - a stuck page-batch refill)
  - open fd count / total fhold refs - fd/file leak across connect churn
  - dentry cache size - dentry leak from per-connection file opens (PG opens many files per backend)
  - fork-arena page count (core/fork_arena.cc) - COW pages not reclaimed on backend exit
  - the g_* map sizes (should stay flat if erase works - confirm empirically, do not trust the source)
  - a thread-state histogram AT the wedge point (all-in-do_idle? behind dentry_hash_lock? on a cv?
    compare to the prior wedge: 32 vCPUs halted, empty wakeup mask, global_l2._nr=0, 184 behind
    dentry_hash_lock)

## THE FIX (once named): return whatever leaks on backend reap. Generic OSv fork/teardown fix - helps
## ANY long-running fork-heavy workload (a DB churning connections for weeks), PG the forcing function.
## This is the REAL production question: a per-boot wedge is a showstopper the reboot-per-cell bench hid.

## VALIDATION: the churn loop must go FLAT (no monotonic growth, no wedge) with the fix, over many
## rounds. Then a HammerDB multi-cell-per-boot run should no longer degrade. Then FILE the PR.

## SUBSTRATE: on Debian host, raw NVMe passthrough. If the leak is guest-internal (a counter grows), it
## is OSv-side and substrate-independent (would reproduce on FC + bare metal) - note that; FC/metal
## confirmation is a separate follow-up.

## Also STANDING METHODOLOGY FIX: fresh boot per HammerDB cell (quiesce is NOT enough - does not reset
## the leak). And do NOT void the fresh r1 as "cold" - on OSv the fresh run is the CLEAN one; the a2a
## run voided the healthy r1 and kept degraded reps, which is how the decline artifact was manufactured.

## CONFIRMED by the spinverdict run (agent ccc5615b): the decline was a run-order ARTIFACT.
- Fresh-boot VU32 = 215,504 NOPM (healthy, ~2x VU16, no collapse). The ~9.3k triplet was a degraded 4th
  cell on a shared boot.
- The a2a run: ALL cells on ONE boot (only 2 console-run logs; one served 3h22m with 109 "autovacuum
  worker took too long" wedge markers). It VOIDED the clean r1 (158k) as "cold-inflated" and kept
  degraded r2-4 (~104k). The M1 decline curve was manufactured by contamination + discarding the clean cell.
- Live 0-NOPM wedge signature: 33/34 KVM vCPUs SLEEPING (idle-WAITING, NOT spinning -> idle-spin is NOT
  the tax), qemu ~0.65 vCPU busy, 69 active PG backends, wait_event = LWLock:WALWrite=33 + NULL-wait=32.
- Spin verdict: SECONDARY now (run-order swamps it; at healthy 215k the guest is ~13% host CPU, not
  CPU-bound, so idle-spin has spare cycles - inference, not the measured trio). Isolate finding survives
  (single continuous workload, not multi-cell).

## NEW CONCRETE LEAD for the leak hunt: AUTOVACUUM WORKER WEDGE.
109 "autovacuum worker took too long to start" markers in the wedged boot. autovacuum forks a worker per
table/cycle continuously (independent of connection churn). If autovacuum workers do not reap cleanly OR
cannot be started (fork/launch wedge), they accumulate exactly like connection-churn backends -> the same
progressive wedge. So the churn-loop repro should ALSO watch: does autovacuum keep launching workers, and
do they reap? The wedge may be triggered by autovacuum's continuous forking even MORE than by client
connection churn. The 0-NOPM wait (LWLock:WALWrite + NULL-wait) says backends block on WAL-commit AND on
a lost wake - consistent with the wakeup-latency theme, but now as a PROGRESSIVE lost-wake accumulation.

## Leak-hunt repro should include BOTH: client connect/disconnect churn AND letting autovacuum run
## (do NOT disable it) - autovacuum's per-cycle worker fork may be the primary driver. Sample per-round
## + watch the autovacuum-worker-start log markers as a wedge proxy.
