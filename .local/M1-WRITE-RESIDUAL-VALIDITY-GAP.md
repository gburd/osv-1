# CRITICAL validity gap before building a write-path fix: the Linux WRITE-latency split was NOT measured.

## What we HAVE
- OSv per-lwb latency split: WRITE ~270us (70%), FLUSH ~110us. Measured on OSv.
- Linux flush RATE: 7077/s at t8 (vs OSv ~3000/s). Measured on Linux, same NVMe.
- OSv write bio round-trip: 145-211us; abd_borrow_buf_copy (8k memcpy, ~few us) in the path.

## What we DO NOT have (the gap)
- The LINUX per-lwb WRITE-vs-FLUSH latency split on the same device. We have Linux flush RATE but not
  Linux WRITE latency. So "the OSv ~270us write is OSv overhead" is INFERRED, not proven against Linux.

## The reasoning error I caught in my own analysis
I cited "plain pwrite = 6us vs lwb write = 270us -> 264us is OSv overhead". But a plain pwrite to ZFS is
almost certainly a BUFFERED write (ARC / async txg) that NEVER does a synchronous device round-trip. A
ZIL write MUST reach the device synchronously. So 6us (pagecache) vs 270us (device sync) is NOT a valid
comparison - it conflates a buffered write with a durable device write. The 6us proves nothing about
the ZIL write path.

## Why this matters (the two outcomes need DIFFERENT fixes, or NO fix)
- If Linux ZIL device-WRITE latency is ALSO ~150-270us on this NVMe -> the write latency is largely
  device/transport (an 8k durable write to instance-store NVMe just costs that), and the OSv-vs-Linux
  flush-RATE gap is NOT the write latency but how many WRITES are concurrently outstanding / pipelined.
  Then the fix is depth/concurrency, not shaving the write, and shaving the write would be wasted work.
- If Linux ZIL device-WRITE is MUCH lower (~half) -> OSv has real write-path overhead (abd copy,
  zio stages, a slow virtio-blk write submit) and shaving it is the fix.
The measured facts do not yet distinguish these. Building a write-path fix now = the exact
"build before the discriminating measurement" trap that has cost this campaign repeatedly.

## THE DECISIVE MEASUREMENT (next run, cheap, no fix)
On the SAME m5d.metal + same NVMe, Debian host:
  1. OSv: per-lwb WRITE latency + FLUSH latency + depth (already instrumented on bench/lwbpipe).
  2. LINUX-ZFS (same device, same recordsize=8k/ashift=12/sync=standard): the SAME split - per-lwb
     WRITE latency, FLUSH latency, and lwbs-in-flight. Via zil kstats / bpftrace on
     zil_lwb_write_issue -> write_done and write_done -> flush_done, or the same probe idea.
  Compare OSv-WRITE-latency vs Linux-WRITE-latency directly. THAT decides whether the residual is
  OSv write-path overhead (fixable) or device physics + a depth/pipeline difference (different fix).

## Also worth resolving in the same run: the depth contradiction
STEP 1a said OSv keeps 6-14 lwbs in flight (mean 1.5); an earlier note said "Linux ~99 in flight".
The agent flagged the Linux-99 came from a kprobe that "fires ONCE per call but the call issues 1+
lwbs" - so the 99 may be an artifact. RECONCILE: measure Linux in-flight depth the SAME way as OSv
(direct gauge), so the OSv-vs-Linux depth comparison is apples-to-apples. If Linux depth is actually
similar to OSv (~1.5) but Linux WRITE latency is half, the whole gap is write latency. If Linux depth
is genuinely much higher, it is pipelining. This MUST be nailed before a fix.

## Status: DO NOT build the write-path fix until the Linux WRITE-latency split + matched depth are in.
#1509 default-on stands (measured isolate win, shipped). The write residual is localized on OSv but NOT
yet validated as OSv-overhead-vs-device. One more measurement run decides the fix (or refutes the need).

## DECISIVE MEASUREMENT DISPATCHED (agent ae830f9b, 2026-09-15, Debian host)
Measure-only, no fix, no HammerDB. OSv (bench/lwbpipe probes) vs Linux-ZFS, SAME NVMe, SAME geometry:
per-lwb WRITE latency + FLUSH latency + in-flight depth (measured the SAME way both OSes), threads=8/16/32.
Three outcomes:
  - Linux WRITE ~= OSv, Linux depth >> OSv -> fix = pipeline DEPTH (shaving write is wasted).
  - Linux WRITE << OSv at similar depth -> fix = shave OSv write path (abd copy / zio / virtio-blk write).
  - Linux WRITE ~= OSv, depth ~= OSv -> gap elsewhere, redirect.
This is the discriminator that decides the write-path fix direction (or refutes the need). NO fix until
it lands - avoids the "build before the discriminating measurement" trap.

## Local source check done (narrows): OSv vdev_disk WRITE bio is plain BIO_WRITE, no FUA/sync flag.
So the write is NOT per-write-durability-forced at the vdev level. The abd_borrow_buf_copy (synchronous
8k memcpy per write) is in the path but ~few us, not 200us. So if OSv write IS slower than Linux, the
cost is in the virtio-blk submit->completion or zio stages, not a FUA flag. The measurement localizes it.
