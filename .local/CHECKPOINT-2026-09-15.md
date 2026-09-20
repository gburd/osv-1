# Program checkpoint 2026-09-15: the M1 investigation, honestly

## The M1 question and where it stands
Goal: stock PostgreSQL on OSv+OpenZFS at parity-or-faster vs PG/Linux under HammerDB, matched substrate.
STATUS: NOT met. Best matched result: OSv declines VU8(104k)->VU16(64k) while Linux scales
159k->269k. The gap is now FULLY DECOMPOSED (not a mystery), measured OSv-vs-Linux on identical
m5d.metal + raw-passthrough NVMe + matched ZFS geometry, with byte-identical probes:
  WRITE:  OSv 288-372us vs Linux 140-266us  (~2x)   <- dominant per-lwb cost, ~300us mean, fat tails
  DEPTH:  OSv mean ~2 in flight vs Linux ~14 (~14x)  <- Linux pipelines far more outstanding lwbs
  FLUSH:  ruled OUT as a fix target (see below)

## Hypotheses tested and REFUTED by measurement on the ZIL/commit path (the discipline that got here)
  1. depth-1 pipeline serialization       -> REFUTED (OSv overlaps up to 11 lwbs)
  2. issuer pacing / commit window         -> REFUTED (waiter ~60us, widening window HURTS)
  3. block-completion drain (#1509)        -> real isolate +33-38%, HammerDB NULL
  4. wakeup fan-out under zl_lock (Lever1) -> real 7x zl_lock cut, throughput NULL
  5. LWB flush pipeline depth ~1           -> REFUTED (depth 6-14, pipeline works)
  6. flush = INTERRUPT-taskq hops (inline) -> REFUTED (whole flush pipeline 38.5us; substrate SYMMETRIC,
                                              branch fired 100%; the ~100us "flush" is NOT the hops)
Each refuted by a cheap measurement before a PR or a false claim. flush residual now attributed to the
WRITE portion / measurement boundary, not a fixable hop.

## SHIPPED / FILED this M1 arc (all master-facing, generic G2, honestly scoped)
  #1502 dentry AB-BA (e2e proven) | #1505 ZIL hires | #1506 ARC-max env | #1507 fsync scan |
  #1508 physio per-iovec | #1509 per-queue completion DEFAULT-ON (+33-38% isolate) |
  #1472 wake-pull default-on | #1510 ext4 read-ahead (draft) | Lever-1 zil-wake-unlocked (contention).
None claimed as M1 parity - each is a real defect/improvement whether or not it moved NOPM.

## Substrate wins (operator directives, applied)
  - Debian 12 native qemu 7.2.22 boots OSv, NO fedora container / -M pc-avoidance hack. Directive works;
    harness simplified. q35 still hangs (AHCI regression is q35-specific, not qemu-version).
  - QEMU is NOT the scaling-shape cause (decline reproduces on FC + native + qemu); it adds a lower
    absolute ceiling (FC virtio-mmio) but not the shape. Answered the operator QEMU concern.
  - The flush-comparison substrate confound I worried about (host-XFS-fsync vs raw-device) RULED OUT:
    both arms raw passthrough. So the WRITE/DEPTH numbers are on clean, symmetric, identical hardware.

## THE NEXT DISCRIMINATOR (not yet run): write-latency vs pipeline-depth
Does OSv write SLOWER (fix = shave the ~300us write path) or keep FEWER in flight (fix = raise write-
issue depth)? If OSv kept 14 writes outstanding like Linux, rate=depth/latency would ~7x AT THE SAME
per-write latency -> DEPTH is likely the bigger, cheaper lever. MEASURE why OSv keeps only ~2 in flight
(issuer cadence / a serializing wait on the WRITE-issue side, distinct from the flush). This is the next
run: one measurement decides write-shave vs depth-raise, then build the named fix, isolate A/B, HammerDB.

## Honest cost/benefit note for the operator
We are ~8 EC2 runs deep on the ZIL/commit critical path. It has produced: 9 real upstream PRs, a fully
decomposed and Linux-contrasted root cause, and a validated substrate - but NOT yet HammerDB parity. The
remaining WRITE+DEPTH levers are named and one measurement from a fix direction. This is genuine G2
platform work (every fix helps any fsync-heavy OSv workload), with PG as the forcing function. Worth one
more measure->fix->benchmark cycle on WRITE/DEPTH; if that also nulls on HammerDB, the honest conclusion
may be that OSv's ZFS-write path needs deeper work than single fixes, and that should be stated plainly.
