# HOP-BY-HOP round-trip profile — c8 vs c32 — RESULT (incremental)

## Instance
- instance-id: **i-074d607e06e4da260** (m5d.metal, us-east-2, real bare-metal KVM, acct 840154381708/beef)
- Base branch: pr/rss-substrate tip **2a029c9a9** (= 6b71c76385 fork-stack + c94fbee57 sched-disperse
  + c7230e5c5 MSI-X bound + 14d86c0c3 virtio-net MQ + 2c30f7570 rxbuf-refcount + 2a029c9a9 virtio-net RSS).
  NOTE: this is NEWER than dad77b7fa (the L1/L2 base named in the task); the RSS/MQ substrate is already
  present on this branch. Will confirm the collapse reproduces on this tip first.
- Build image=zfs-tools,pg18-fork fs=zfs conf_zfs=openzfs conf_fork=1, DEFAULT mmap (NOT sysv per LEVER1).

## GOAL
Decompose the per-request round-trip HOP-BY-HOP to find where the +~2.5ms/query at c32 vs c8 accumulates.
5 hops: H1 NIC-RX->receiver-wake, H2 receiver classify+push+wake, H3 wake->backend-run,
H4 backend compute+reply-write, H5 TX->client->next-RX. wakeprof already said H3 is only ~8%; find the ~92%.

## STATUS: instance launching. Studying instrumentation points next.

## HOP-BY-HOP BREAKDOWN (measured, WAKE_STEAL off = stock sched, tap0 real NIC, smp32, -s50 RO)
Collapse reproduced: **c8 = 84,732 tps @ 0.094ms  ->  c32 = 32,481 tps @ 0.985ms** (+0.89ms/query).

Per-window deltas (RXPROF+WAKEPROF, cumulative-snapshot subtraction):

| Hop                         | c8 window     | c32 window    | growth |
|-----------------------------|---------------|---------------|--------|
| H1 batch (pkts/drain-pass)  | 2.68          | **1.22**      | DROPS (receiver under-batched, NOT queueing) |
| H1 drain_avg (pass walltime)| 5.8 us        | 5.9 us        | flat |
| H1q per-pkt queueing (pass_start->post) | ~4.4 us | ~7.1 us | +2.7 us |
| H2 post_packet (classify+push+wake) | 1.45 us | 1.46 us | **FLAT** |
| H3 wake->run (window avg)   | 5.4 us        | **15.0 us**   | **2.8x** |
| H3 wakes/query              | 1.72          | 2.53          | +47% |

### ATTRIBUTION of the +0.89ms/query
- H3 (wake->run) total per query: c8 = 1.72*5.4us = 9.3us; c32 = 2.53*15.0us = 38us -> **+29 us**.
- H1q + H2 per query: a few us, ~flat.
- **OSv-internal RX+wake hops (H1+H2+H3) sum to ~35 us = ONLY ~4% of the +890us added latency.**
- The receiver is NOT the queue: batch DROPS to 1.22 pkts/pass at c32 (it drains ~1 pkt per wakeup),
  drain walltime is flat 5.9us, H2 is flat. The single serial receiver is NOT the bottleneck (H1 NULL).
- => the remaining **~96% (~855 us) is H4 (PG compute) + H5 (TX -> client -> next RX round-trip)**,
  OUTSIDE the OSv RX/wake path. This EXTENDS the wakeprof verdict (H3 was ~8% there, ~4% here).

### NEXT: isolate H4 vs H5 (smp1 A/B, TX-path check) to decide reducible-vs-floor.

## ISOLATION EXPERIMENTS (all smp32 unless noted, WAKE_STEAL off, tap0 real NIC)

### smp1 (single CPU: no cross-CPU IPI, no placement) -- NO COLLAPSE, flat plateau
| c   | 1     | 2     | 4     | 8     | 16    | 32    | 64    |
|-----|-------|-------|-------|-------|-------|-------|-------|
| tps | 13.3k | 20.4k | 20.4k | 19.7k | 19.7k | 19.9k | 18.1k |
| lat | 0.075 | 0.098 | 0.196 | 0.406 | 0.811 | 1.610 | 3.528 |
smp1 tps PLATEAUS at ~20k (one CPU saturated); latency = concurrency * ~50us EXACTLY (Little's
law, one server). SERVICE TIME per query ~= 50us. NO collapse -- just a flat single-server plateau.

### smp8 vs smp16 vs smp32 single-queue -- IDENTICAL (collapse is NOT CPU-count-driven)
| c   | smp8  | smp16 | smp32 |
|-----|-------|-------|-------|
| c8  | 88.9k | 88.9k | 88.1k |  <- peak, same
| c16 | 40.0k | 39.1k | 41.2k |  <- cliff, same
| c32 | 35.2k | 33.4k | 34.1k |  <- same
| c64 | 30.2k | 29.7k | 30.4k |  <- same
Adding CPUs beyond ~8 neither helps nor hurts. The collapse is intrinsic to CONCURRENCY, not
cross-CPU spread. Rules out cross-CPU cache/lock contention as the primary driver.

### single-queue vs MULTIQUEUE tap (queues=8, mq=on) -- MQ PARTIALLY reduces the collapse
| c   | single-q | MQ x8 | delta |
|-----|----------|-------|-------|
| c1  | 13.9k    | 15.8k | +13%  |
| c8  | 88k      | 92k   | +5%   |
| c16 | 41k      | 55k   | **+34%** |
| c32 | 34k      | 40k   | +16%  |
| c48 | 29k      | 32k   | +12%  |
| c64 | 30k      | 28k   | -8%   |
The RSS/MQ substrate on this branch LIFTS the mid-range (c16 +34%, c32 +16%) but does NOT flatten
toward Linux (130-159k). So the single RX+TX queue serialization is PART of the cost (reducible),
but a residual collapse remains that more queues do not fix.

### HOST CPU during c32 (mpstat) -- machine 97% IDLE, backends PARKED not computing
- host idle 97.2%, qemu %cpu = 3.6 cores of 96 (during 30k tps / 1.05ms).
- Work is ~50us (smp1); round-trip is 1050us; machine 97% idle -> ~1000us is WAITING, not compute.
- H1+H2+H3 (OSv RX+wake hops) sum to ~35us. The other ~965us is time the request spends between
  those events: TX reply -> tap/vhost -> host -> pgbench client -> next request -> RX interrupt.

## ROOT CAUSE (which hop grows + why, on a 97%-idle machine)
The dominant growing hop is **H5: the TX-reply -> client -> next-RX-interrupt round-trip**, NOT any
OSv-internal RX/wake hop. Evidence:
- RXPROF: the single receiver drains ~1 packet per wakeup (batch n1 dominates) with a ~70-80us
  GAP between drain passes -- it is LATENCY-bound waiting for the next RX interrupt, not throughput-
  bound. It is NOT queueing packets behind each other (H1 batch DROPS at c32). H1 = NULL (confirms L1).
- H2 post_packet is FLAT (~0.6-1.5us). NULL.
- H3 wake->run grows 2.8x (5.4->15us) but * wakes/query = only ~35us/query = ~4% of the +890us. Minor.
- The +~890us at c32 is the request-reply ROUND-TRIP through the single virtio-net TX + tap/vhost +
  host + client + RX-interrupt path lengthening under concurrency (vhost/IRQ coalescing + the single
  TX queue serializing 32 backends' replies). MQ (more RX/TX queues) reduces it ~16-34%, proving
  part is the single-queue serialization; the rest is the per-request 2-context-switch + real
  tap/vhost NIC round-trip that thread-per-request cannot shrink below.

## VERDICT: PARTIALLY REDUCIBLE (RSS/MQ substrate) + a THREAD-PER-REQUEST + vhost-NIC round-trip FLOOR
- REDUCIBLE part: the single RX+TX virtio-net queue. The RSS/MQ substrate already on this branch
  (VIRTIO_NET_F_MQ + F_RSS) lifts c16 +34% / c32 +16% when the tap exposes multiple queues.
- FLOOR part: with MQ active the collapse still does NOT flatten to Linux. The residual is the
  per-request round-trip -- 2 context switches + a real tap/vhost RX-interrupt round-trip (~70-80us
  receiver inter-pass gap) that grows with in-flight concurrency and is a property of thread-per-
  request over a virtio-net/vhost NIC, not a fixable single serialization point. smp1 shows the
  actual work is ~50us and there is NO collapse; the collapse is the multi-client round-trip queueing
  the single NIC path cannot pipeline past ~c8.



## ADDITIONAL ISOLATION (confirming the verdict)

### SLIRP vs tap+vhost (NIC-path A/B) -- the NIC path shifts the peak; collapse persists
| c   | tap+vhost | SLIRP    |
|-----|-----------|----------|
| c8  | 88k       | 67k      |
| c16 | 41k       | **91k**  |  <- SLIRP peak HIGHER + LATER than tap's c8 peak
| c32 | 34k       | 36k      |  <- both collapse
| c64 | 30k       | 34k      |
SLIRP (userspace NIC, no vhost IRQ coalescing) moves the peak c8->c16 and raises c16 41k->91k =>
H5 (NIC egress / IRQ path) is a real reducible factor governing WHERE the peak is. Both paths
still collapse past ~c16-c32 => a residual collapse independent of the NIC path.

### smp1 vs smp8/16/32 -- collapse is cross-CPU-engaged but NOT cpu-count-scaled
- smp1: NO collapse (flat ~20k plateau; latency = concurrency*50us). No cross-cpu wakes exist.
- smp8 == smp16 == smp32: IDENTICAL collapse. Cross-cpu wakes engage at >1 cpu but adding cpus past
  ~8 neither helps nor hurts. Peak ~88k@c8 ~= 4-5 parallel pipeline stages (88k / 20k single-cpu).

### L2 wake-placement (wake_steal) -- the fix that WOULD target the residual, but UNSAFE
- Made env-toggleable (OSV_WAKE_STEAL) for a clean A/B.
- BUG 1 (fixed): migrated a waking thread via suspend_timers() without cpu::unlink_parked() first
  -> assert(!_parked_link.is_linked()) at park_timers. Fixed to match the load_balance migration.
- BUG 2 (architectural, NOT fixed): still asserts p_status!=queued at reschedule. Migrating a waking
  thread to a THIRD idle cpu + fixing its per-cpu vars from the WAKER's cpu is not atomic w.r.t. the
  idle cpu's scheduler -> double-enqueue race. A correct fix needs a real select_task_rq (choose the
  cpu before enqueue, by the owning cpu) = a substantial scheduler change. AND LEVER1 already proved
  moving wakes cross-cpu is IPI-bound (~2x IPIs) and does not convert idle cpus to throughput.
  => wake_steal left OFF by default (unsafe under load); unlikely to flatten even if made correct.

## BOTTOM LINE (the answer to the open question)
The per-request round-trip is **PARTIALLY REDUCIBLE, then hits the thread-per-request + single-NIC
round-trip FLOOR**:
- The DOMINANT growing hop is H5 (TX reply -> vhost/tap -> host -> client -> next RX interrupt),
  NOT any OSv-internal RX classify/wake hop. H1 (receiver serial drain) = NULL (batch drops to 1,
  drain flat) -- re-confirms LEVER1. H2 = flat. H3 (wake->run) = ~4% of the added latency.
- REDUCIBLE lever that WORKS: the RSS/multiqueue substrate on this branch. With a multiqueue tap it
  lifts c16 +34% and c32 +16%. That is the generic, PG-agnostic, master-PR-worthy net fix (already
  the RSS/MQ commits on pr/rss-substrate) -- it needs the host NIC to expose multiple queues.
- FLOOR: even with MQ the collapse does not flatten to Linux (130-159k). The machine is 97% idle;
  the ~1ms/query at c32 is almost all WAITING in the per-request request/reply round-trip that
  thread-per-request over a virtio-net/vhost NIC cannot pipeline past ~c8-c16. That is the
  architectural limit -- we peeled the RX-dispatch (L1 null), the wake-issue (batch null), and now
  the RX/wake hops measure ~4%; the residual is the round-trip itself.

## CLEANUP
- instance i-074d607e06e4da260 TERMINATED (terminate accepted -> shutting-down; slow metal teardown).
- qemu reaped (0 procs), all docker containers removed (0), no other metal instance of mine running.
- root vol-063b49dc5b314a4ea DeleteOnTermination=true (auto-deletes on termination); local NVMe ephemeral.

## COMMIT
- 142e1b92e on pr/rss-substrate: RXPROF hop profiler + wake_steal env toggle + parked_link migration
  fix. Bench instrumentation (not a standalone upstream PR as-is). The REDUCIBLE fix (RSS/multiqueue)
  is the pre-existing pr/rss-substrate commits (14d86c0c3 MQ, 2a029c9a9 RSS) -- the standalone
  master-PR-worthy net/sched change; validated here to lift c16 +34% / c32 +16% with a multiqueue tap.
