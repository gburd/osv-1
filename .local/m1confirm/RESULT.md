# M1-confirm: does #1509 (virtio-blk per-queue completion) move HammerDB NOPM and close the M1 gap?
# Date 2026-09-14. Same-binary A/B (OSV_BLK_MQ_COMPLETE off vs on), one image, one variable.

## Boxes (AWS lava, us-east-2, Owner=agent-m1confirm) -- BOTH TERMINATED (see Housekeeping)
    i-016b920108bf9e216  m5d.metal   m1confirm-metal  16.59.122.4 / 172.31.14.9  (OSv SINGLE+PERQ arms + host)
    i-01dabeee6f235c8c3  c5.4xlarge  m1confirm-drv    18.119.128.13 / 172.31.0.55 (HammerDB driver)

## The A/B was VALID -- two DIFFERENT boot-mode console lines, num_queues>1 both:
    SINGLE arm:  OSV_BLK_MQ_COMPLETE: virtio-blk completion mode=single    num_queues=32
    PERQ   arm:  OSV_BLK_MQ_COMPLETE: virtio-blk completion mode=per-queue num_queues=32
Same image (8f1a560, gate PASS incl #1509 req_done_q lock-free), same m5d.metal, same physical NVMe,
same qemu 8.1.3 -M pc KVM guest, PG 18.6 musl, 200wh/19GB, ZFS ashift=12/recsize=8k/sync=standard,
32 vCPU/64GiB, fsync=on synchronous_commit=on io_method=sync, all 12 GUCs source=command line.
Substrate note: dropped the explicit iothread (qemu 8.1.3 has no iothread-vq-mapping; a single iothread
would funnel host-side completion and produce a FALSE null). Default main-loop keeps per-vq MSI-X.
WAL path verified on the mq device: data_directory=/data/pg on ZFS pool imported from /dev/vblk1.

## HEADLINE (medians, settled repeats, cold r0 voided)
    VU     SINGLE median    PERQ median    delta%       Linux (matched, a2a3lever same substrate)
     8      103,984         (no-op*)        --          159,792
    16       67,055          70,152         +4.6%        268,921
    32      WEDGED**         61,361          --          (not run; declines vs Linux VU16)
  * #1509 is a no-op at low concurrency by design (one completion thread suffices); SINGLE VU8=103,984.
  ** SINGLE VU32 wedged x3 via the fork/worker-start hang (nondeterministic, NOT the dentry deadlock).

  SINGLE shape: 103,984 (VU8) -> 67,055 (VU16) = -36%, then wedge  (DECLINES, as established)
  PERQ   shape:              70,152 (VU16) -> 61,361 (VU32) = -13%  (STILL DECLINES)

## The three questions, answered straight
(a) Does PERQ raise NOPM? NO, not at settled load. VU16 +4.6% (within run-to-run noise ~8-10%).
(b) Does PERQ stop the VU8->VU16 decline? NO. It does not scale; it declines VU16->VU32 just as SINGLE
    trends. NULL-wait RISES with VU in both arms (SINGLE 68-74% -> PERQ 77-78% at VU16, 87% at VU32).
(c) VU16/32 instruments -- does PERQ show more vCPUs busy + higher NVMe util (the fix working)?
    NO at settled load:  qemu vCPU busy 11.8 (SINGLE) vs 12.3 (PERQ) at VU16; NVMe %util 22-28% vs
    25-27%; total completion-work jiffies ~355k vs ~371k -- NEAR-IDENTICAL. The per-queue threads have
    nothing extra to parallelize because the device sits ~74% IDLE in both arms.
    YES in COLD/backlog drain (voided for NOPM but diagnostically decisive): PERQ VU16 r0 hit 56% util
    (max 89%), VU32 r0 hit 63% util (max 96%), aqu-sz 5, 580MB/s -- SINGLE NEVER exceeded ~28% util /
    aqu-sz 1.0 in any run. The fix DOES drive the device 2-3x harder AND lift throughput WHEN QUEUES
    ARE FULL (the +58% isolate condition). Steady-state HammerDB never fills the queues.

## WHAT THE RESULT MEANS (the important null, not massaged)
PERQ ~= SINGLE at settled HammerDB load. The isolate win (+58% concurrent durable-write) required a
SATURATING concurrent-writer load; HammerDB TPROC-C at 200wh is NOT WAL-completion-throughput-bound at
steady state -- it is NULL-wait bound (77-87% idle-stall, device ~74% idle, ~12-18/32 vCPU busy). The
backends serialize on something UPSTREAM of the block-completion drain: the WAKEUP fan-out after a
commit completes, not the drain itself. #1509 parallelizes the drain; it does not parallelize the
wakeup. So #1509 helps the isolate and cold-backlog bursts but does NOT move the steady-state HammerDB
ceiling and does NOT close the M1 gap. This redirects the next target to the WAL-commit WAKEUP path
(cv_broadcast fan-out / scheduler wake placement after commit), consistent with a2a3lever's residual.

#1509 is NOT throughput-qualified by HammerDB. It remains isolate-qualified (+58% durable-write) and
generically correct (helps any workload that fills the queues). Default OFF is right.

## Lock-free req_done_q correction HELD (critical safety check)
No PERQ run wedged with 0-runnable. All 0-NOPM events were HammerDB CLI init flakes (main.tcl line 146)
with PG fully reachable (select 1 = 1) and normal guest thread mix -- NOT a deadlock. The corrected
lock-free drain did not deadlock under HammerDB ring-full pressure.

## Substrate caveat (per steering, sets expectations for the NEXT benchmark)
This is qemu 8.1.3 -M pc, a test convenience, not a deployment target. Prior evidence: qemu -M pc
distorts the scaling shape (a Firecracker run ROSE to a VU16 peak where qemu -M pc declines). So the
PERQ~=SINGLE null is valid (qemu held constant, one guest variable), but absolute parity-to-Linux on
this substrate is not the point. If the remaining ceiling is qemu-side (plausible: device 74% idle,
NULL-wait dominant), Firecracker is where OSv scaling separates from qemu artifacts. The completion fix
being a null here does NOT rule it out on a substrate that actually fills the queues.

## Linux placement (matched, same substrate, from a2a3lever -- NOT re-measured; deprioritized)
OSv-PERQ / Linux ratio: VU16 = 70,152 / 268,921 = 0.261x. Linux SCALES VU8->VU16 (+68%); OSv-PERQ does
not. #1509 did not narrow this. (Cross-run comparison on the identical substrate config; the a2a3lever
Linux arm was fully matched -- 32GiB ARC proven binding, same qemu/NVMe/GUCs.)

## Housekeeping
Both boxes terminated; 0 tagged instances, 0 tagged volumes remaining (see terminate log).
