# SIGMQ campaign 2026-08-04 (box i-06bfdb84020e37732, m5d.metal, local NVMe, us-east-2 beef)

Substrate: 861be4908 (fork-stack #1458 tip w/ W1 mmu fix). ZFS pgdata on a raw
file on instance-store NVMe (xfs /mnt/nvme). KVM -cpu host, -smp 32 (avoids the
-smp>=56 boot fault). PG18-musl-PIE, default mmap (no sysv), shared_buffers=1G.
qemu 8.1.3 in a fedora:39 --network host --device /dev/kvm --init container.

## JOB D: SIGUSR1 DROP-DATABASE crash — VALIDATED (reproduced-then-fixed A/B)

Fix under test = a02c4631b's libc/signal.cc change, cherry-picked cleanly onto
861be4908 (single 45-line commit, signal.cc ONLY; #if CONF_fork gated).
Bundle: .local/sigmq-bundles/sigusr1-inline-validated.bundle (861be4908..sigmq-fixed,
tip d2bc07b31). Diff vs 861be4908 = libc/signal.cc +45, nothing else.

Workload: pgbench load holding 48 backends connected + tight CREATE DATABASE x
TEMPLATE template0 / DROP DATABASE x loop. DROP DATABASE emits a ProcSignalBarrier
that must SIGUSR1-signal every connected backend.

UNFIXED (861be4908), -smp32:
  - Run 1 (heavy-write pgbench load, 48 conc): DROP DATABASE dbx4 HUNG on
    "still waiting for backend with PID 5072 to accept ProcSignalBarrier"
    (140 retries, permanent deadlock; select-1 still worked = postmaster alive).
  - Run 2 (clean RO -S load, 48 conc): 18 CREATE+DROP OK, then iter 19 HUNG on
    ProcSignalBarrier (backend PID 4667 never acks; waits grew 30->70; DROP
    permanently deadlocked).
  => REPRODUCED 2/2. Manifests as a HANG (barrier never acknowledged) rather than
     the "exception nested too deeply" abort — same root cause (the spawned
     SIGUSR1 handler thread runs in the wrong AS, sets ProcSignalBarrierPending in
     AS0's copy not the backend's COW-private copy, backend spins forever).

FIXED (861be4908 + signal.cc inline self-signal), -smp32:
  - Clean RO -S load, 48 conc: 40/40 CREATE+DROP DATABASE clean, 0 ProcSignalBarrier
    hangs, 0 EIO.
  - Heavy-write load: 6/6 DROP DATABASE clean (0 barrier hangs), then hit the
    SEPARATE pre-existing write-path EIO corruptor at iter 7 ("could not write
    blocks 16752 EIO" during checkpoint) — a DIFFERENT bug (ROADMAP BLOCKER 2,
    the sustained-concurrent-write corruptor), NOT the barrier bug.

VERDICT: the fix CLEARS the SIGUSR1/ProcSignalBarrier COW-AS delivery bug.
Reproduced on unfixed (hang), fixed leg 0 hangs. PR = YES.
Re-sign d2bc07b31 (or a02c4631b) + open. It is a real, now-validated fork-stack
hardening fix.

## JOB E: MQ (#1463) re-measure on the FIXED substrate

Substrate = 861be4908 + #1464 sched (512b2b2ec) + #1467 batch-wake (794fe0f0e) +
#1463 MQ (3ed80ccb2), cherry-picked + conflicts resolved. Pushed as
gh-fork/pr/virtio-net-multiqueue-substrate (tip e88b0ff9f).

CORRECTNESS BUG FOUND + FIXED during substrate bring-up:
  The batch-wake (#1467) receiver holds osv::rcu_read_lock across the WHOLE drain
  pass; the non-classified slow path ((*if_input)()->tcp_input) takes a blocking
  mutex under it -> "Assertion failed: preemptable() (sched.hh:1350)". The
  substrate's own in-build ZFS-builder VM boot CRASHED here. Fix (commit e88b0ff9f):
  flush the wake batch + release rcu_read_lock around the slow path, re-take after.
  After the fix the substrate boots 10/10 and serves. This is a real #1467 bug
  (surfaces where the preemptable() assert is active) that the standalone #1467
  smp>1 payoff run never hit.

A/B (SAME substrate image, MQ nqp=8 multiqueue-tap vs single-queue nqp=1, -smp32,
fresh ZFS pool re-seeded per leg; 2 fresh-pool runs each, tps):
  RO  c8  MQ 50558 / SQ 50915  (0.99x)
  RO  c16 MQ 42200 / SQ 33531  (1.26x)
  RO  c32 MQ 22569 / SQ 17469  (1.29x)
  RO  c48 MQ  4755 / SQ  6061  (0.78x)
  RW  c8  MQ  5562 / SQ  5995  (0.93x)
  RW  c16 MQ  6511 / SQ  7642  (0.85x)
  RW  c32 MQ  1275 / SQ  1625  (0.78x)
  RW  c48 MQ   760 / SQ   686  (1.11x)
  Run-to-run variance 20-40% (dirty-pool + wake-latency noise).

  => MQ shows a MODEST, NOISY RO gain at mid concurrency (c16/c32 ~1.26-1.29x) but
     a consistent RW LOSS and no win at the highest concurrency (c48). NOT the
     "MQ beats single-queue at high concurrency" hoped for. The dominant limiter is
     the ~c8 RO ceiling + wake round-trip latency (#1464/#1467 territory), not queue
     count — confirming the earlier "MQ doesn't fix concurrency" verdict HOLDS on
     the fixed substrate.

EIO / vector-starvation check:
  nqp=8 smp32: 0 EIO across 3 runs.
  nqp=16 smp32 (net claims up to 34 MSI-X vectors): boots fine; heavy RW c32/60s =
  0 EIO, 0 failed txn, 5838 tps.
  => The MSI-X vector-budget code carried IN #1463 (== the #1465 split content)
     PREVENTS net-starves-blk in this 2-blk-device config. The prior EIO was
     nqp16/smp16 with 7 blk devices (a tighter budget). No EIO reproduced here.

VERDICT: #1463 MQ is CORRECT-AS-IS on the vector-budget axis in tested configs
(no EIO, no boot crash at nqp8/nqp16), BUT NOT-WORTH-IT as a concurrency feature:
it does not beat single-queue reliably (RW loses, RO gain is within noise, no
high-concurrency win). Recommendation: keep #1463 PARKED/draft; the useful boot-
crash fix already lives in #1465. Do NOT merge #1463 as a performance feature.
The #1467 rcu-scope fix (e88b0ff9f) IS a real correctness fix worth landing on
#1467.
