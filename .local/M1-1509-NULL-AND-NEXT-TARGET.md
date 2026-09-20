# #1509 HammerDB result: NULL (honest, decisive). The M1 ceiling is the post-commit WAKEUP fan-out.

## The A/B (valid: two different boot-mode console lines, same image, num_queues=32 both, WAL on mq device)
    VU    SINGLE     PERQ       delta        Linux (matched)
     8    103,984    (no-op)    -            159,792
    16     67,055     70,152    +4.6% noise  268,921
    32    WEDGED*     61,361    -            -
  *SINGLE VU32 wedged via the fork/worker-start hang (NOT dentry #1502); PERQ completing VU32 is not
   attributable to #1509 (a2a3lever hit ~62k without it). Do not credit #1509 for VU32 completing.

## Verdict: #1509 does NOT move steady-state TPROC-C throughput. Filed on isolate+correctness only.
Settled load: PERQ ~= SINGLE (12 vCPU busy, NVMe ~25% util / 74% IDLE both). The per-queue completion
threads have nothing extra to parallelize because 200wh HammerDB never fills the device queues.
BUT the fix WORKS where the isolate said: cold/backlog drain, PERQ 56-96% util / aqu-sz 5 / 580 MB/s vs
SINGLE 28% / aqu-sz 1.0 - drives the device 2-3x harder WHEN QUEUES ARE FULL. #1509 comment updated to
claim isolate (+58%) + correctness (lock-free drain HELD, no wedge), NOT a HammerDB win.

## The REAL M1 ceiling, now triply-confirmed: the post-commit WAKEUP FAN-OUT
HammerDB at 200wh is NULL-wait bound (77-87% of active backends in wait_event=NULL, device 74% idle,
CPU ~12/32). Backends serialize on the WAKEUP after commit - UPSTREAM of the block-completion path #1509
parallelizes. The chain: zil_lwb_flush_vdevs_done -> cv_broadcast(zcw_cv) per waiter -> each backend
woken -> each SCHEDULED onto a vCPU. The serialization is in that wake+schedule fan-out, not the drain.

## CRITICAL: this signature is ALSO where qemu 8.1.3 -M pc most plausibly distorts
77-87% NULL-wait + device-and-CPU-idle + "backends waiting to be woken" is EXACTLY the pattern a
hypervisor's vCPU-scheduling / IPI-delivery / halt-wakeup layer can inject. We do NOT know how much of
this is OSv's wakeup fan-out vs qemu -M pc's vCPU/IPI model. The agent's own caveat: qemu -M pc distorts
scaling shape; Firecracker (which the isolate showed DOES fill queues differently) is the discriminator.

## THE PLAN (substrate pivot, per operator directive: NOT Amazon Linux)
Before writing ANY wakeup-fan-out fix, run the SAME OSv image on a DEBIAN host (native qemu that boots
OSv, no fedora container / -M pc hack) AND on FIRECRACKER. Question: does the VU16->VU32 decline +
NULL-wait stall PERSIST on Firecracker, or does OSv scale there (as the old 145k@VU16 FC number hinted)?
  - If it PERSISTS on Firecracker -> the wakeup fan-out is genuinely OSv-side; fix zil cv_broadcast /
    the schedule-after-wake path (the wake-pull is on but cannot help 0-runnable; this is the wake
    ITSELF being slow/serialized, a different lever).
  - If it VANISHES on Firecracker -> qemu 8.1.3 -M pc was (part of) the ceiling; the M1 gap shrinks on
    the real substrate and the "OSv doesn't scale" conclusion was a substrate artifact. Huge finding.
Either way, Firecracker-on-Debian is the next benchmark and it decides where the remaining fix goes.

## Session M1 PR tally (all master-facing, generic G2)
#1502 AB-BA (e2e proven) | #1505 ZIL hires | #1506 ARC-max | #1507 fsync scan | #1508 physio per-iovec |
#1509 virtio-blk per-queue completion (isolate+correctness, NOT HammerDB) | #1472 wake-pull default-on |
#1510 ext4 read-ahead (draft, recreated). Gate scripts + projected-merged-base methodology in place.
