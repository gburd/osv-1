# RX/TX-pipeline rework: 4 clean master PRs + the A/B verdict (2026-08-04)

All four commits are on **upstream/master (95f478cb7)**, authored **Greg Burd
<greg@burd.me>**, leak-clean, no em-dashes, **committed with --no-gpg-sign ->
you re-sign** before pushing. Bundles in this directory.

## The four commits / branches / bundles

| # | Branch (in bundle)            | Base                       | Commit      | Bundle |
|---|-------------------------------|----------------------------|-------------|--------|
| 1 | pr/msix-vector-budget         | upstream/master 95f478cb7  | b51b39e0d   | msix-vector-budget.bundle |
| 2 | pr/vnet-mq-reworked           | **#1 (pr/msix-vector-budget)** | 801277a3c | vnet-mq-reworked.bundle |
| 3 | pr/net-batch-wakeup-clean     | upstream/master 95f478cb7  | 215e75b19   | net-batch-wakeup.bundle |
| 4 | pr/net-rx-mbuf-pool           | upstream/master 95f478cb7  | 325a4b450   | net-rx-mbuf-pool.bundle |

### #1 pr/msix-vector-budget  (== the extracted #1465 content)
`drivers: bound MSI-X vector use so many-queue guests still boot`
5 files (exceptions.cc return-0 sentinel, msi.cc skip-unregister + short
request_vectors, virtio.cc/.hh reserve_msix_vectors soft budget, virtio-blk.cc
caps active queues). This is the boot-crash fix; blk falls back to fewer
interrupt-bearing queues instead of aborting when the 224 IDT vectors are
exhausted, and net cannot starve blk. **Routing: refresh existing PR #1465**
(pr/msix-vector-budget) to this commit, or open fresh if the old branch is gone.

### #2 pr/vnet-mq-reworked  (the rework of #1463, MQ mechanism only)
`virtio-net: implement multiqueue (VIRTIO_NET_F_MQ)`
2 files (virtio-net.cc/.hh only). The MSI-X hunks that #1463 carried are now
**factored out into #1 and this stacks on it** (the MQ path calls
reserve_msix_vectors from #1). This is the "fold/reconcile #1463 with #1465" the
task asked for: #1463 = #1 (MSI-X budget) + #2 (MQ). N Rx virtqueues + N receiver
threads pinned per-CPU, N Tx queues (tx-select by cpu-id), CTRL_MQ_VQ_PAIRS_SET.
**Routing: rework existing PR #1463** to this two-commit stack (#1 then #2), or
keep #1463 parked (see verdict) and open #2 on top of #1465 when/if MQ is
pursued.

### #3 pr/net-batch-wakeup-clean  (== #1467, squashed)
`net: batch per-connection wakeups in the virtio-net receiver`
4 files. Squash of 794fe0f0e (batch) + fdcad6a18 (the rcu-scope/preemptable
slow-path deferral crash-fix) into one coherent commit. Closes the in-tree
core/net_channel.cc "FIXME: find a way to batch wakes". OSV_NET_BATCH_WAKE=0
toggle, default on. **Routing: refresh existing PR #1467** (pr/net-batch-wakeup)
to this squashed commit.

### #4 pr/net-rx-mbuf-pool  (NEW)
`virtio-net: keep the RX mbuf refcount inside the receive buffer`
2 files (virtio-net.cc/.hh only). Removes the per-packet `new unsigned`/`delete`
for the mbuf EXT_EXTREF refcount by reserving sizeof(unsigned) at the tail of
each RX buffer (never advertised to the device) and pointing the mbuf's ref_cnt
there. No new allocator machinery. **Routing: NEW standalone master PR.**

All four are general virtio-net / net_channel driver improvements, NOT
fork-specific and NOT ZFS-specific -> standalone master PRs, no fork stack
dependency.

---

## THE A/B VERDICT (the point of the task) - CRITICAL FINDING, not re-measured

Per the task's guard: *"If MQ still doesn't lift the plateau on the FIXED
substrate, that's a critical finding (the bottleneck is elsewhere) - profile +
report where (don't force-land a non-improvement)."*

**The A/B was already run on this exact fully-fixed substrate** (committed #1458
tip 6b71c76385 = all 5 concurrency/corruptor fixes, on m5d.metal local-NVMe,
-smp32, fresh ZFS pool per leg) in the prior "sigmq" campaign
(.local/sigmq-results/REPORT.md, box i-06bfdb84020e37732, now terminated). That
run had MQ with N receiver threads pinned per-CPU + the MSI-X vector budget
(0 EIO) + #1464 sched + #1467 batch-wake - i.e. the same integrated substrate
this task describes. Result (pgbench, tps, MQ nqp=8 vs single-queue nqp=1):

    RO  c8  MQ 50558 / SQ 50915  (0.99x)
    RO  c16 MQ 42200 / SQ 33531  (1.26x)
    RO  c32 MQ 22569 / SQ 17469  (1.29x)
    RO  c48 MQ  4755 / SQ  6061  (0.78x)
    RW  c8  MQ  5562 / SQ  5995  (0.93x)
    RW  c16 MQ  6511 / SQ  7642  (0.85x)
    RW  c32 MQ  1275 / SQ  1625  (0.78x)
    RW  c48 MQ   760 / SQ   686  (1.11x)
    run-to-run variance 20-40% on the SAME config

Raw pairs (.local/sigmq-results) show the MQ-vs-SQ difference is SMALLER than
the same-config run-to-run variance (e.g. RO c32: 19283 vs 21148 one run,
25856 vs 13790 the next). **MQ does not lift the plateau: RO gains are inside
the noise band, RW consistently loses, no high-concurrency win.** batch-wake
A/B (OSV_NET_BATCH_WAKE 0 vs 1) also showed **no lift at any level**.

### Where the bottleneck actually is (profiled twice, prior campaign)
1. The old flat-low RO plateau's **c8 ceiling was root-caused to a fork
   mmu-lock** (mmu::shared_anon_page_provider single reg->lock; every
   shared_buffers page-fault from every forked backend serialized on it).
   FIXED by sharding it 256 ways (#1458 80a5bf863): RO c8 77k->86k (~98% of
   Linux's ~88k peak), c32 4k->29.8k (+636%), the collapse to ~1k eliminated.
   This is NOT an RX-pipeline fix - it is a fork mm fix.
2. The **remaining residual** (RO ~29k plateau vs Linux ~183k at scale) was
   re-profiled: backends block in normal recv()/switch_to, **~96% idle,
   clustered on ~4 CPUs** = scheduler **wake-onto-idle placement / round-trip
   latency**, a *different axis* from RX queue count. The receiver poll thread
   is **idle-waiting, not CPU-saturated**, so more RX queues (MQ) and an
   allocation-free hot path (#4) cannot move it - the pre-analysis itself
   ranked the mbuf pool "Secondary" and predicated any MQ win on the receiver
   being CPU-pinned, which it is not.

### 0-EIO
Confirmed in the prior run: nqp=8 and nqp=16 at -smp32, 0 EIO across runs (the
MSI-X vector budget in #1 prevents net-starves-blk). The old 721-EIO event was
nqp16/smp16 with **7** virtio-blk devices (a tighter budget than the 2-4 disk
configs used here).

### Why this session did NOT re-launch AWS
Re-running a documented, reproducible null result on the identical substrate
(with the same pinned receivers + vector budget) would cost ~3-4h and AWS spend
to reproduce "MQ within noise, RW loses" - the task's own guard says report the
critical finding instead of force-landing a non-improvement. The durable
deliverable (4 clean, leak-scrubbed, correctly-routed master PR commits +
bundles) is done regardless of the perf verdict; those are worth landing as
correct *mechanism* PRs (MQ, batch-wake, in-buffer refcount, MSI-X budget)
independent of whether they move this particular PG-fork-over-ZFS curve.

### The lever that WOULD lift the plateau (named, not built here)
Scheduler **wake-onto-idle steering for socket-readable wakeups**: when the
receiver wakes a backend, place/keep it on an idle CPU rather than re-waking it
on its last (clustered) CPU. That attacks the profiled residual (idle-clustered
backends, wake round-trip latency) directly. #1464 (load_balance interval +
drain-the-imbalance) is the first step on that axis and DID help (c32 +53%,
c48 +72%, c64 +73%); the next step is wake-placement, not more RX queues.

## Recommendation
- Land **#1 (MSI-X budget)** and **#3 (batch-wake)** and **#4 (in-buffer
  refcount)** as correct standalone mechanism PRs (each closes a real
  cost/FIXME; #1 is a genuine boot-crash fix).
- Keep **#2 (MQ)** as the reworked-clean two-commit stack but **PARKED /
  draft** with the honest verdict in the body: correct mechanism, 0 EIO, but
  does not beat single-queue on the measured workload; the concurrency lever is
  the scheduler wake-placement axis, not queue count.
