# The QEMU question (operator, 2026-09-14): are we testing the wrong substrate?

## The answer: yes, partly. QEMU 8.1.3 -M pc is a test convenience, not a deployment target,
## and there is direct evidence it distorts the scaling shape.

### Why we ended up on QEMU (history, not justification)
OSv boots under QEMU/KVM; it was the low-friction iteration path. A trap forced a SPECIFIC qemu: AL2023
host qemu 11 cannot boot OSv (AHCI hang under -M q35, PR #1498), so every recent run is:
    EC2 metal -> KVM -> fedora:39 container qemu 8.1.3 -M pc -> OSv guest.
Nobody SHIPS OSv this way. The real targets are Firecracker (the unikernel design target) and bare metal.

### Operator's point is correct: the two execution models that matter are Firecracker and on-instance.
The north-star literally specifies a hypervisor MATRIX (KVM + Firecracker + native) x both ISAs. We have
been benchmarking ONE cell - the least representative one - and treating its numbers as THE OSv numbers.

### What QEMU does and does NOT confound
- Does NOT confound the SINGLE-vs-PERQ A/B (same qemu held constant; the fix result stands).
- The OSv-vs-Linux RATIO is only partly protected: qemu overhead is NOT symmetric. Linux has a mature,
  multiqueue-by-default virtio-blk driver and a scheduler tuned for the KVM/qemu vCPU model; OSv is a
  young guest. qemu 8.1.3 -M pc could penalize OSv MORE (esp. IPI/halt/vCPU-thread interactions - the
  wedge/idle-stall signature is exactly what a hypervisor vCPU layer can distort). So the gap may be
  partly a qemu-8.1.3-M-pc artifact that DISfavours OSv.

### DIRECT SUPPORTING EVIDENCE (same OSv, different hypervisor, different SHAPE)
    Firecracker (16-vCPU, 40wh): VU8 113,323 -> VU16 145,073 (PEAK) -> VU32 136,521   RISES, gentle
    qemu 8.1.3 -M pc (32-vCPU, 200wh): VU8 104,640 -> VU16 64,839 (DECLINES) -> VU32 WEDGE
Firecracker RISED to a VU16 peak; qemu -M pc declines at VU16 and WEDGES at VU32. Not a clean A/B (16 vs
32 vCPU, 40 vs 200 wh, different bases) but the SHAPE divergence is a strong signal the hypervisor is
part of the scaling story - possibly a large part.

## PLAN
1. FINISH the current QEMU A/B (agent 0c90e588). It cleanly isolates the #1509 fix (qemu held constant)
   and reproduces the a2a baseline (SINGLE VU8 ~104k / VU16 ~67k = matches), so PERQ-vs-SINGLE is valid.
   Worth having: it tells us if the fix works AT ALL, cheaply.
2. THEN move the whole benchmark to FIRECRACKER - the real target - as the next substrate. This:
   - tests the actual deployment model (unikernel under Firecracker), and
   - SEPARATES OSv scaling from qemu-8.1.3-M-pc artifacts. If OSv scales on Firecracker where it
     wedged on qemu, QEMU was (part of) the ceiling - a major finding that reframes the M1 gap.
   Prerequisite check: OSv-under-Firecracker with ZFS-on-local-NVMe (Firecracker uses virtio-blk over
   MMIO, not PCI - confirm the driver path + num_queues story differs; Firecracker MQ support varies by
   version). The prior 145k FC run was 16-vCPU/40wh; redo matched to the 32-vCPU/200wh/32GiB-ARC config.
3. Also worth: native/bare-metal (OSv as the only thing on the instance) - the other real model - but
   Firecracker first since it is the primary target and the cleaner A/B against the same KVM substrate.

## Standing methodology change
Benchmark the DEPLOYMENT models (Firecracker, native), not the iteration convenience (qemu -M pc).
QEMU stays only for quick dev-loop smoke tests, never for a headline parity/scaling number. Every
benchmark result must record its hypervisor, and a parity claim requires Firecracker and/or native.

## UPDATE (2026-09-14): the Firecracker A/B was ALREADY run (2026-08-18, .local/ZFS-MATRIX-FC.md).
It answers the QEMU question, and the answer is nuanced:

OSv-FC vs Linux-FC, matched, ZFS-on-virtio-blk under Firecracker v1.7.0 (8-vCPU, s10):
  c1 RO 0.98x / RW 1.01x (PARITY) -> c8 0.52x/0.55x -> c32-64 ~0.24x RO / ~0.33x RW plateau.

VERDICT (the agent's, verified): the decline-with-concurrency SHAPE is the SAME on Firecracker AND
native AND QEMU - OSv wins/ties c1, peaks c8, then a fixed per-request decline while Linux climbs. So:

  - QEMU is NOT the cause of the scaling SHAPE. The process-per-connection / wakeup-fan-out tail
    reproduces on ALL THREE substrates. Your hypothesis (QEMU causes the scaling collapse) is REFUTED
    for the SHAPE: it is genuinely OSv-side (the fork + post-commit wakeup model).
  - QEMU/Firecracker DO differ on absolute CEILING: FC virtio-mmio (single-queue, no vhost) is ~2-3x
    SLOWER transport than QEMU virtio-pci+vhost. So the earlier "FC peaked 145k" was a DIFFERENT,
    smaller/older config; on matched config FC is LOWER absolute than QEMU, not higher.

So the two hypotheses resolve:
  (a) "QEMU causes the scaling collapse" -> NO, the collapse is OSv-side, same on all substrates.
  (b) "QEMU absolute numbers are unrepresentative" -> YES, but FC is LOWER not higher, so QEMU was if
      anything FLATTERING the absolute level, not penalizing it. The REAL deployment (FC) is slower
      absolute, same shape.

## CAVEAT that keeps Firecracker on the plan anyway
That FC A/B was an OLD build (79ed402f4), 8-vCPU, s10, 128MB shared_buffers - BEFORE #1507 fsync-scan,
#1472 wake-pull-default-on, #1509 per-queue completion, #1502 AB-BA. It is not comparable to the current
32-vCPU/200wh M1 numbers. So a CURRENT-base Firecracker run is still worth it - to (1) confirm the fixes
help on the real substrate, and (2) get the true deployment number. But we should NOT expect it to
reveal QEMU as the culprit - the shape is OSv-side and already reproduced on FC + native.

## The REAL target stands: the post-commit wakeup fan-out (OSv-side, substrate-independent).
The #1509 null + this FC-shape-matches result both point to the SAME place: the wakeup after commit,
not the block-completion drain and not the hypervisor. That is where the M1 fix must go.

## Substrate directive still applies: next benchmark host = DEBIAN (not Amazon Linux), and use OSv's
## first-class FC support (scripts/firecracker.py, virtio-mmio, PVH boot) - which is proven working.
