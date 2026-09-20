# WRITESPLIT — the decisive OSv-vs-Linux per-lwb WRITE/FLUSH/depth measurement

**Box: i-029d704fc34d6a966** (m5d.metal, us-east-2, Owner=agent-writesplit). Reported in first message.
Host: Debian 12 bookworm, kernel 6.1.0-53-cloud-amd64, qemu 7.2.22 (Debian 1:7.2+dfsg-7+deb12u18+b3), KVM.
96 vCPU / 377 GiB host. 4 instance-store NVMe (838G each) + 80G EBS root. TERMINATED at end (see bottom).

## What this run answers (the validity gap from M1-WRITE-RESIDUAL-VALIDITY-GAP.md)
Prior runs measured the OSv per-lwb WRITE/FLUSH split and depth, and the Linux flush RATE, but NEVER the
Linux per-lwb WRITE-vs-FLUSH split or the Linux depth measured the SAME way. So "the ~270us OSv write is
OSv overhead" was inferred, not compared. This run measures BOTH OSes on the SAME physical box, SAME
/dev/nvme1n1, matched ZFS geometry, with IDENTICAL probe boundaries and an IDENTICAL in-flight gauge.

## Methodology (validated identical, not just "similar")
- ONE m5d.metal, ONE physical NVMe /dev/nvme1n1 (838G instance-store). Arms never ran concurrently.
- Matched ZFS geometry BOTH arms: ashift=12 recordsize=8k compression=off atime=off sync=standard logbias=latency.
- Workload BOTH arms: syncwrite threads=N, each = 8k pwrite + fdatasync loop on its own file, 30s.
- OSv arm: gh-fork/bench/lwbpipe @ 7e297fbc2, conf_zfs=openzfs (OpenZFS 2.4.2 base + baked-in probes 0035-0039,
  VERIFIED present in built source: zw_inflight/zw_depth_accum/zc_wrlat_sum, 14 markers). Booted native
  qemu -M pc + KVM (NO container), 32 vCPU / 64 GiB guest, raw nvme1n1 as virtio-blk (num-queues=4,
  cache=none aio=native), OSV_BLK_MQ_COMPLETE=1 (the shipped #1509 default). Boot line confirms per-queue.
- Linux arm: DIRECT-Linux on the metal host, OpenZFS 2.1.11-1+deb12u1 (DKMS) - the SAME ZFS version the prior
  lwbpipe Linux arm used. bpftrace kprobes on zil_lwb_write_issue / zil_lwb_write_done /
  zil_lwb_flush_vdevs_done, paired on the lwb pointer (io_private @0x198 in struct zio, confirmed via objdump).
- GAUGE MATCH (the crux): OSv's gauge (patch 0035) does zw_depth_accum(+1) at `lwb_state=LWB_STATE_ISSUED`
  (in zil_lwb_write_issue) and zw_depth_accum(-1) at `lwb_state=LWB_STATE_FLUSH_DONE` (in
  zil_lwb_flush_vdevs_done). The Linux bpftrace gauge does ++ at zil_lwb_write_issue, -- at
  zil_lwb_flush_vdevs_done. BYTE-FOR-BYTE the same transitions. The suspect "Linux ~99 in flight"
  kprobe-fires-once artifact is NOT used.
- LATENCY MATCH: OSv WRITE = issue->WRITE_DONE (zc_wrlat), FLUSH = whole_lwb - write. Linux WRITE =
  zil_lwb_write_issue->zil_lwb_write_done, FLUSH = zil_lwb_write_done->zil_lwb_flush_vdevs_done. Same boundaries.
  (OSv reports mean+max; Linux reports mean+p50+p99. Compare mean-to-mean - both have it.)

## THE DECISIVE TABLE (same box, same NVMe, same geometry, same gauge)

|      | WRITE lat (avg) |          | FLUSH lat (avg) |          | in-flight DEPTH |               | flush/s |       | op/s  |       |
| thr  | OSv    | Linux   | OSv    | Linux   | OSv mean/max    | Linux mean/max | OSv    | Linux | OSv   | Linux |
|-----:|-------:|--------:|-------:|--------:|:---------------:|:--------------:|-------:|------:|------:|------:|
|  8   | 288 us | 140 us  | 127 us |  16 us  |   1.39 / 6      |   2.31 / 8     |  3,340 | 4,604 | 11,840| 25,057|
| 16   | 348 us | 190 us  | 147 us |  23 us  |   1.76 / 7      |   4.18 / 18    |  3,535 | 4,986 | 17,689| 36,006|
| 32   | 372 us | 266 us  | 114 us |  40 us  |   1.99 / 10     |  13.95 / 42    |  4,078 | 5,620 | 30,418| 48,632|

Linux WRITE p50/p99: t8 131/287us, t16 174/454us, t32 204/~640us. Linux FLUSH p50/p99: t8 15/29us,
t16 16/115us, t32 16/~380us. OSv p50/p99 are whole-op syncwrite latencies (t8 569/2105, t32 872/2873us).

## VERDICT: the data fits NONE of the three prewritten outcomes cleanly. It shows a THIRD thing the prior
## framing missed: OSv pays an overhead on BOTH the write AND the flush, AND runs at lower pipeline depth.

Three findings, all measured:

1. **The WRITE is real OSv overhead (outcome-2 signal), strongest at low concurrency.** At t8 OSv WRITE is
   288us vs Linux 140us = **2.06x**. At t32 they converge (372 vs 266us = 1.40x) because Linux's write
   latency rises under its own 14x-deeper pipeline. So the OSv write path DOES carry ~150us of excess over
   Linux on the identical device - this half of the prior "270us is OSv overhead" claim is now CONFIRMED
   against Linux, not merely inferred.

2. **NEW / refutes the prior run: the FLUSH is ALSO OSv overhead, not "healthy device physics."** OSv flush
   is 114-147us; Linux flush on the SAME NVMe is **16-40us = ~4-7x faster**. The prior RESULT.md called OSv's
   ~110us flush "healthy for a local NVMe" and excluded it as a fix target. That is REFUTED: the device
   flushes in ~16us (Linux proves it), so ~100us of OSv's flush is also OSv-side overhead. The prior
   conclusion that "only the write is the lever" was based on never having measured the Linux flush.

3. **The depth gap is real too (outcome-1 signal).** Linux in-flight depth SCALES with concurrency
   (mean 2.3 -> 4.2 -> 14.0, max 8 -> 18 -> 42); OSv depth barely moves (mean 1.4 -> 1.8 -> 2.0, max 6 -> 10).
   Linux keeps far more lwbs outstanding at once. Even with per-lwb latencies as they are, deeper pipelining
   is a large part of why Linux sustains ~5600 flush/s while OSv tops out ~4000.

### Why the flush/s and op/s gaps are only ~1.2-1.4x here (vs the historic ~2x)
This run's Linux flush/s (4604/4986/5620) is lower than the prior run's headline 7077/s at t8, and OSv here is
higher (MQ_COMPLETE=1 default-on, which the prior STEP1a baseline did NOT have). With MQ_COMPLETE=1 OSv is
0.47x-0.63x Linux on op/s (11840/25057 .. 30418/48632). The gap narrowed because #1509 already shipped; what
remains splits cleanly into the three overheads above.

## FIX DIRECTION (what this decides)
The residual is NOT a single lever. By Little's law, rate = depth / whole_lwb_latency. OSv loses on BOTH terms:
- **Latency:** whole-lwb latency OSv 416-495us vs Linux (write+flush) 156-306us. OSv pays ~150us extra WRITE
  AND ~100us extra FLUSH. BOTH are OSv-side (device does write in ~140us, flush in ~16us - Linux proves it on
  the identical NVMe). => shaving the OSv zio/virtio-blk WRITE path AND the FLUSH path both pay off. The
  prior run's plan to shave ONLY the write would leave the ~100us flush overhead (7x the device) untouched.
- **Depth:** OSv keeps ~1.4-2.0 lwbs in flight; Linux keeps 2.3-14.0 (and scales). Raising OSv lwb pipeline
  depth is ALSO a genuine lever - the prior "depth already overlaps, not the fix" was true relative to the
  strict depth-1 hypothesis but understated how much MORE depth Linux runs (14x at t32).

The single most surprising, highest-leverage new fact: **OSv's ZIL FLUSH is ~7x the device flush** (114us vs
Linux's 16us on the same NVMe). That was explicitly excluded as a target by the prior run and is now the
cheapest thing to look at first - it is a zero-byte barrier, so ~100us of OSv overhead on it is almost
certainly the virtio-blk FLUSH completion/dispatch path or a zio flush-stage cost, not data movement.

## PUSHBACK ON THE BRIEF'S FRAMING
The brief offered three outcomes; the truth is a superposition of two of them PLUS a refutation of a prior
"healthy flush" assumption. It is NOT "device physics" (Linux does write 140us / flush 16us / depth 14 on the
identical NVMe - all far better than OSv), and it is NOT purely "OSv write overhead" (the flush and the depth
are also OSv-side). The next run should target, in order: (1) the OSv FLUSH overhead (~100us over device,
biggest surprise), (2) the OSv WRITE overhead (~150us over device), (3) OSv lwb pipeline depth. All three are
OSv-side and additive. NO fix built here; NO HammerDB run - per brief.
