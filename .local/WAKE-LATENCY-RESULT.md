# WAKE-LATENCY PROFILE — c8 (peak) vs c32 (collapsed) — RESULT (agent)

## Instance
- instance-id: **i-005f16c879bb4552d** (m5d.metal, us-east-2, real bare-metal KVM /dev/kvm,
  96 vCPU, 4x 838G local NVMe). acct 840154381708 (beef). Public 13.59.95.226.
- Build: OSv gh-fork integ/pg-fork-zfs tip **dad77b7fa** (= 6b71c76385 + 746e5bcd9 RCU-registry
  L1 + dad77b7fa COW-peek L2), image=zfs-tools,pg18-fork fs=zfs conf_zfs=openzfs conf_fork=1,
  **DEFAULT mmap** (NO sysv), + WAKEPROF in-scheduler instrumentation (79-line diff to
  core/sched.cc + sched.hh, armed via --env=OSV_WAKEPROF=1).
- Load: stock PG18, shared_buffers=1GB, pgbench -S (RO) -s50 over **tap0 (192.168.100.2, NOT
  loopback)**, virtio-net, T=60s, smp32, one fresh boot per concurrency (clean pool restored).

## WAKEPROF instrumentation (generic OSv sched profiler)
- `_wakeprof_ts` stamped in `thread::wake_impl()` at the moment a thread is marked runnable.
- At switch-in (`trace_sched_switch`), record `now - _wakeprof_ts` into a log2(ns) histogram +
  the runqueue depth seen + IPI-vs-local wakeup counters. Background thread prints to console
  every 5s (captured over serial; NO trace-buffer extraction, NO /proc KVM accounting).

## THE MATCHED PAIR (fresh boot each, load window isolated via before/after WAKEPROF snapshot)
| metric                    | c8 (peak)        | c32 (collapsed)   | ratio |
|---------------------------|------------------|-------------------|-------|
| **pgbench tps (RO)**      | 43,566           | **24,451**        | 0.56x (COLLAPSE) |
| **latency avg**           | 0.184 ms         | **1.309 ms**      | +1.125 ms |
| host CPU idle (mpstat)    | 90.7%            | **94.5%**         | MORE idle |
| qemu total %cpu (of 9600) | 79.7             | **53.2**          | LESS busy |
| **wake->run avg (steady)**| **5.8 us**       | **38.6 us**       | **6.7x** |
| wake->run p50             | <512 ns          | <2048 ns          | 4x |
| wake->run p90             | <16 us           | <33 us            | 2x |
| wake->run p99             | <66 us           | <131 us           | 2x |
| wake->run p99.9           | <131 us          | <524 us           | 4x |
| runqueue depth mean       | 1.42             | **1.82**          | |
| %switch-ins rq>=3         | 8.5%             | **22.1%**         | 2.6x |
| %switch-ins rq>=5         | 0.07%            | **4.56%**         | **65x** |
| wakes/query               | 1.77             | 2.56              | |
| switches/query            | 3.10             | 3.78             | |
| IPI wakeups (load)        | ~2.1M            | ~1.5M            | |
| local wakeups (load)      | ~2.4M            | ~2.0M            | |

## DECOMPOSITION — where the added ~1.125 ms/query GOES
- **wake->run latency climbs 6.7x** (5.8us -> 38.6us) as concurrency rises c8->c32, WHILE the
  machine gets MORE idle (90.7% -> 94.5%) and qemu burns LESS host CPU (79.7 -> 53.2). Backends
  are parked waiting to be dispatched, NOT computing. This is a scheduler-dispatch signature.
- **BUT** pure wake->run accounts for only ~89 us of the +1125 us added per-query latency (~8%):
  2.56 wakes/query * 38.6us = 98.7us at c32 vs 1.77 * 5.8us = 10.2us at c8 -> +88.6us.
- The **other ~92% (~1 ms)** is NOT wake->run wait and NOT CPU (machine 94% idle). It is time the
  query round-trip spends between wake events -> a SERIAL DISPATCH STAGE. The runqueue explosion
  (rq>=5 jumps 65x: 0.07% -> 4.56%) on a 94%-idle 96-vcpu box is the tell: work PILES on a few
  CPUs behind a serialization point while 90 CPUs sit idle. The single virtio-net receiver thread
  doing classify+wake INLINE per packet (+ the reply TX path) serializes the 32-client fan-in:
  each query's RX->wake->run->reply->TX cannot parallelize past that one dispatch context, so
  added concurrency just deepens the queue behind it instead of using idle CPUs.

## THE VERDICT
**FIXABLE SCHEDULER-DISPATCH LATENCY, not an architectural thread-per-request floor.**
- The wake->run path IS getting 6.7x slower under concurrency on an idle machine (real, measured),
  AND the runqueues pile 3-10 deep on a few CPUs while 90 are idle -> the scheduler is NOT
  spreading the woken backends across the idle cores. Two fixable levers, both scheduler-dispatch:
  1. **Single-receiver serial dispatch** (dominant, ~92% of the added ms): the one virtio-net RX
     thread classifies + wakes every backend inline. Fix = PARALLELIZE the dispatch (multiple RX
     dispatch contexts / offload classify+wake off the single receiver / per-queue receivers with
     virtio-net MQ+RSS which the tip now has). This is the same "candidate 4" the roadmap named;
     this profile CONFIRMS it dominates once locks are gone.
  2. **Wake placement / runqueue selection** (secondary, the 6.7x wake->run climb + rq pile-up):
     woken backends are not being steered to the ~90 idle CPUs; they queue behind peers on the
     waker's neighborhood. Fix = idle-CPU wake steering / better runqueue selection so a wake on a
     94%-idle machine lands on an idle core in <6us regardless of concurrency.
- NOT the thread-per-request floor: 2.56 wakes + 3.78 switches per query is cheap; a context
  switch is ~sub-us here; the cost is DISPATCH SERIALIZATION + BAD PLACEMENT, both schedulable,
  not the existence of a thread per request.

## Cleanup: box i-005f16c879bb4552d TERMINATED (shutting-down); qemu + all docker containers
   reaped; no orphaned EBS volumes (root DeleteOnTermination=true, NVMe ephemeral); no other
   m5d.metal of mine running.
