# M1-confirm: does #1509 (virtio-blk per-queue completion) move HammerDB NOPM and close the M1 gap?

## The question
Isolate win is proven (+58% aggregate durable-write throughput at 16 writers). Does that translate to
HammerDB TPROC-C NOPM, and does OSv stop declining VU8->VU16 (SINGLE declined 104k->65k)?

## The A/B: ONE variable, ONE image
Base branch `gh-fork/bench/m1-confirm` (8f1a560), all M1 levers + #1509 (req_done_q, lock-free drain).
    arm SINGLE : OSV_BLK_MQ_COMPLETE=0 (unset)  historical single completion thread
    arm PERQ   : OSV_BLK_MQ_COMPLETE=1          one completion thread per virtqueue
Boot line to CAPTURE every run: `OSV_BLK_MQ_COMPLETE: virtio-blk completion mode=<single|per-queue> num_queues=N`
If both arms print same mode -> A/B VOID. If num_queues=1 -> fix is a no-op (test meaningless).

## Pre-launch gate: PASS
`sh .local/bench-base-gate.sh <tree>` on gh-fork/bench/m1-confirm: all required fixes present incl
#1509 req_done_q (3). req_done_q body is LOCK-FREE (0 WITH_LOCK in body -- deadlock-corrected version).

## Boxes (AWS lava, acct, us-east-2, Owner=agent-m1confirm)
    i-016b920108bf9e216  m5d.metal   m1confirm-metal  16.59.122.4 / 172.31.14.9  (OSv arms + Linux arm + host)
    i-01dabeee6f235c8c3  c5.4xlarge  m1confirm-drv    18.119.128.13 / 172.31.0.55 (HammerDB driver)

## Substrate change vs a2a3lever
Pool virtio-blk device (hd1) now gets num-queues=$CPUS + dedicated iothread so num_queues>1
(the fix needs it). Root disk (hd0, rofs image) stays single-queue.

## Matched config (identical both arms, and vs Linux)
Same m5d.metal, same physical NVMe, qemu 8.1.3 KVM guest for OSv AND Linux. PG 18.6 musl both,
200wh/19GB, ZFS ashift=12/recsize=8k/sync=standard, 32 GiB ARC, 32 vCPU/64 GiB, io_method=sync,
fsync=on synchronous_commit=on autovacuum=on. 12 GUCs source=command line.

## Runs
1. OSv A/B: VU 8,16,32,64. Per VU, 3 settled repeats per arm (SINGLE vs PERQ), quiesce (2 consecutive
   sub-1s CHECKPOINTs) before each. Reboot to switch arm. r1-after-cold-import VOIDED.
2. Linux arm same VUs (destroy OSv pool, rebuild Linux on same NVMe), 3 settled repeats.

## Progress log
- [done] gate PASS, branch verified, boxes launched, re-tagged Owner=agent-m1confirm
- [done] host-setup + drv-setup
- [done] OSv image built: usr.img 118,685,696 B (byte-identical to prior verified-good PG image)
- [done] seed boot: pool created once on /dev/vblk1 (hd1), seed_copy, export. Boot line: single num_queues=8
- [done] run boot SINGLE arm: PG 18.6 musl ready; num_queues=32; all 12 GUCs source=command line
- [running] 200wh schema build
- [todo] OSv A/B sweep (SINGLE vs PERQ) VU 8/16/32/64; then Linux arm

## VALIDITY GATES (all PASS -- the independent variable really varies at the device level)
1. num_queues>1: boot line prints num_queues=32 on the pool disk (hd1). Fix has queues to work with.
2. NO single-iothread funnel: qemu 8.1.3 has NO iothread-vq-mapping (that is 9.0+). A single iothread=X
   would serialize ALL vqs' host-side completion drain -> PERQ would read like SINGLE for a SUBSTRATE
   reason (false null). FIXED: dropped the explicit iothread; qemu default main-loop keeps genuine
   per-vq MSI-X delivery, which is what the guest per-queue completion threads parallelize on.
3. WAL on the mq device: data_directory=/data/pg on ZFS pool imported from /dev/vblk1 (hd1, num_queues=32).
   pg_wal is default $PGDATA/pg_wal (no --waldir split). fsync=on synchronous_commit=on io_method=sync.
   The WAL-commit-completion path -- the M1 gap -- goes through the multiqueue device.
4. Completion-spread instrument added: instr.sh now counts busy qemu vCPU threads over the window.
   SINGLE funnels zio_interrupt/cv_broadcast onto few vCPUs; PERQ should light up more. Compared per arm.

## Results (filled as cells complete)
(none yet)
