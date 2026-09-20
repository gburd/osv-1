# WAL-commit-completion serialization: measure which hop gates

BOX: i-0e6411d809a63a1f3 (m5d.metal, us-east-2a, Owner=agent-walwake), IP 3.12.162.104

## Base
bench/walwake-mt (pushed to gh-fork/osv-1) = bench/a2a-shape-fix (all levers:
TCB #1504, fork, ZIL hires #1505, wake-pull #1472, fsync #1507, dentry #1502)
+ scripts/bench/zfs-bench.c from bench/syncwrite-mt (1cdbe3541, the threads=N
concurrent durable-write isolate). ZIL path is representative (#1505 present).
Chose a2a-shape-fix base + cherry-pick the bench tool because syncwrite-mt
itself lacks the ZIL hires fix.

## Source analysis (candidates, traced before measuring)
Completion chain: fdatasync -> zil_commit -> LWB write + FLUSH -> single
virtio-blk req_done thread (drivers/virtio-blk.cc: ONE thread drains all
queues, biodone runs inline) -> zio_interrupt -> INTERRUPT taskq ->
zil_lwb_flush_vdevs_done walks lwb_waiters + cv_broadcast.

- Candidate A: single virtio-blk completion thread (drivers/virtio-blk.cc
  req_done, one thread all queues). F_MQ multi-queue plumbing already present.
- Candidate B: zio INTERRUPT taskq thread count. In
  external/openzfs/module/zfs/spa.c zio_taskqs[][]:
    FLUSH row INTR = ZTI_ONE  (1 thread)   <-- ZIL flush completions land here
    NULL  row INTR = ZTI_ONE  (1 thread)
    WRITE row INTR = ZTI_SCALE(0)
  zio_flush() makes a ZIO_TYPE_FLUSH zio; its completion dispatches to the
  FLUSH INTERRUPT taskq = 1 thread. This serializes zil_lwb_flush_vdevs_done
  (the cv_broadcast fan-out) across all backends. STRONG candidate B.
- Candidate C: scheduling woken backends (wake-pull on, likely not it).

## Plan
STEP 1 MEASURE: syncwrite threads=1,2,4,8,16,32 (fdatasync) + threads=1,8,32
nofsync (control). aggregate op/s + pooled p50/p99. At threads=32: iostat %util
on NVMe + host per-vCPU busy (top -H). Diagnostic: plateau+low util+idle vCPUs
=> completion path is the gate.
STEP 2 (only if plateau): A/B env-gated fix, most likely B (raise FLUSH/NULL
INTR taskq thread count).

## Status log
</content>

- [t0] Box i-0e6411d809a63a1f3 up (96 vCPU, 4x838G instance-store NVMe, /dev/kvm).
  Installed docker 25.0.16 + git (not on AL2023 by default). Build launched from
  gh-fork/bench/walwake-mt (OSV_HEAD 9d8a2747, syncwrite_mt present, ZIL hires present).
  vdev = /dev/nvme1n1 -> virtio-blk vblk1. Guest 32 vCPU / 64 GiB.
  Pool: ashift=12 (create_pool), recsize=8k (passed), sync=standard (ZFS default) - matches PG.

## STEP 1 RESULT — fsync sweep (secs=20 reps=3, medians), guest 32vCPU/64GiB, NVMe ashift=12 recsize=8k sync=standard
threads | agg op/s | scale vs t1 | p50 us | p99 us
1  |  5,376 | 1.00x |  152 |  554
2  |  8,173 | 1.52x |  207 |  715
4  | 11,786 | 2.19x |  287 | 1412
8  | 21,579 | 4.01x |  293 | 1748
16 | 21,749 | 4.05x |  644 | 2240   <-- KNEE: +0.8% op/s but p50 x2.2
32 | 27,772 | 5.17x | 1026 | 2876

PLATEAU confirmed. Linear-ish to t=8 (4x), flatlines t8->t16 (zero throughput gain,
p50 doubles), weak recovery t32. Knee ~8 concurrent committers => the completion/
wakeup path stops parallelizing past ~8 in-flight commits. p50 climbs 152->1026us as
threads pile onto the serialized completion. Matches the hypothesis SHAPE (concurrency
converts to queueing latency, not throughput).

## STEP 1 INSTRUMENTATION at threads=32 fsync (DECISIVE)
- NVMe %util: oscillates 25-56%, median ~40%, aqu-sz 0.5-4.0  => NOT device-bound
- Host CPU: ~89% idle, sys ~4%, iowait 0                       => NOT host-CPU-bound
- Guest vCPU: sum qemu-thread %CPU ~1223% = 12.2/32 vCPU busy   => NOT guest-CPU-bound
  (each of 32 vCPU threads only 35-53% busy: blocked waiting to be woken post-commit)
- Matches M1 exactly (12/32 vCPU, ~28-40% util). CONFIRMS the WAL-commit-completion
  wakeup path is the gate: concurrency past ~8 committers becomes queueing latency,
  not throughput, while device+CPU sit idle.

VERDICT STEP 1: PLATEAU CONFIRMED. The completion/wakeup path IS the gate. Proceed to A/B.

## nofsync control (write-only, no ZIL commit)
t1=180,263  t8=105,145  t32=85,312 op/s  (p50 3.6/74/294 us)
Memory/writeback-bound single-thread ceiling; declines with threads (single-file
writeback contention), NOT the completion path. Confirms fsync path is the one that
serializes on completion - the control behaves totally differently (34x faster at t1).

## STEP 2 A/B — candidate B (zio NULL/FLUSH INTERRUPT taskq width) — REFUTED
Env-gated OSV_ZIO_INTR_THREADS raises the NULL+FLUSH INTERRUPT taskq COUNT
(external/openzfs module/zfs/spa.c spa_taskqs_init). Boot print confirms resolved
value (count=1 off; count=N on). fsync, secs=20 reps=3 medians:

threads | OFF     | ON=2          | ON=4          | ON=8
8       | 21,302  | 20,128 (-6%)  | 16,032 (-25%) | 16,014 (-26%)
32      | 29,792  | 26,470 (-11%) | 27,697 (-7%)  | 26,623 (-11%)

REFUTED. Widening the zio INTERRUPT taskq does NOT lift the plateau; it HURTS
(monotonically worse at higher counts). The zio taskq is NOT the serialization
point. The cv_broadcast fan-out in zil_lwb_flush_vdevs_done is not gated by taskq
thread count. (4th refuted hypothesis on this path - stays consistent with the
"cheap measurement refutes source-traced guesses" pattern.)

## WHERE IT MUST BE: candidate A (single virtio-blk completion thread)
The zio INTERRUPT taskq is DOWNSTREAM of block completion. UPSTREAM of it: every
block completion (LWB write done + device FLUSH done) is drained by the SINGLE
virtio-blk req_done thread (drivers/virtio-blk.cc), which runs biodone ->
vdev_disk_bio_done -> zio_interrupt INLINE before the taskq is even reached. Under
N concurrent commits, N device completions serialize through that ONE thread. That
is the real funnel, and it sits before B (why widening B can't help - the work is
already serialized by the time it reaches the taskq). Next A/B: parallelize the
virtio-blk completion drain (per-queue completion threads under F_MQ).

## STEP 2 A/B — candidate A (per-queue virtio-blk completion) — CONFIRMED (the fix)
drivers/virtio-blk.cc + .hh: env-gated OSV_BLK_MQ_COMPLETE=1 spawns ONE completion
thread per virtqueue (req_done_q), each draining only its own queue, MSI-X vector i
bound to thread i. Default off = the historical single req_done() thread that drains
all queues serially (running biodone->vdev_disk_bio_done->zio_interrupt->
zil_lwb_flush_vdevs_done cv_broadcast INLINE for every completion). make_request()
already steers requests to queue = cpu_id % num_queues, so completions land spread
across queues; one thread per queue lets the wakeup work run in parallel across CPUs.

fsync, secs=20 reps=3, medians (op/s), guest 32vCPU/64GiB, NVMe ashift=12 recsize=8k:

threads | OFF        | A ON (per-queue) | delta   | p50 OFF->ON (us) | p99 OFF->ON (us)
1       |  5,376     |  5,447           |  ~0     | 152->154         | 554->517
2       |  8,173     |  8,547           |  +4.6%  | 207->200         | 715->629
4       | 11,786     | 15,227           | +29.2%  | 287->220         | 1412->1370
8       | 21,302     | 24,024           | +12.8%  | 293->272         | 1748->1734
16      | 21,749/25190| 34,444          | +37-58% | 542->366         | 2169->2010
32      | 27,772     | 40,597 / 41,185  | +46-48% | 1026->648        | 2876->2500

CONFIRMED and reproducible (t32 A-on measured 40,597 then 41,185; OFF t32 stable
27.6-27.8k). At the plateau knee (t16) throughput +58%; at t32 +48% AND p50 latency
halves (1026->648us). The single virtio-blk completion thread WAS the WAL-commit-
completion gate. Low-thread (1,2) unchanged as expected (no concurrency to spread).

FIX: drivers/virtio-blk.cc  mechanism=one completion thread per virtqueue
(req_done_q), env=OSV_BLK_MQ_COMPLETE=1 (default off), MSI-X vector i -> thread i.
GENERIC: yes - a faster durable-write completion drain helps EVERY fsync-heavy /
high-IOPS-completion workload on OSv, not just PostgreSQL. PG was the forcing fn.

## TEARDOWN
Box i-0e6411d809a63a1f3 TERMINATED. Root vol-0265be0e196718c01 DELETED (NotFound).
0 orphan agent-walwake instances, 0 orphan agent-walwake volumes. Confirmed clean.

## FINAL
Deliverable: gh-fork/bench/walwake-mt @ fa513ac54
- drivers/virtio-blk.cc + .hh: OSV_BLK_MQ_COMPLETE per-queue completion = THE FIX
  (+48% at t32, p50 halved, refuted taskq candidate B kept as patch 0033).
See RESULT.md for full A/B numbers.
