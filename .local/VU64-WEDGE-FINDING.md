# VU64 lost-wakeup deadlock - a NEW, OSv-specific residual (2026-09-18, agent df2b1866, DECISIVE)

## THE FINDING (all 4 discriminators, measured on hotdog m5d.metal, matched OSv-vs-Linux)
At VU64 OSv/PG-on-ZFS hits a TRUE, PERMANENT, OSv-SPECIFIC lost-wakeup DEADLOCK on the WAL-commit /
ZIL-completion -> waiter path. Distinct from (and deeper than) the VU32 idle->wake low-mode.

Signature: run starts HEALTHY (~110-116k xact_commit/15s, NVMe 58-97%, qemu 2075-2208% = CPU-saturated)
for ~60s, then FALLS OFF A CLIFF at t~75s to xact_commit_delta=2/15s (housekeeping only), NVMe=0.00,
qemu ~45% of one core (idle), WALWrite waiter pileup, and NEVER RECOVERS for the full 5 min.

## DISCRIMINATORS (each ruled a hypothesis in/out):
(a) DEADLOCK not stall: never recovers (t=75 -> t=360). Permanent lost wakeup.
(b) NOT io_uring-specific: io_method=worker wedges IDENTICALLY (blocks at IO-worker submit, WALWrite
    waiters=5 vs uring 65, but same outcome: commit=2, NVMe=0, idle, never recovers). => the lost wake is
    in the ZFS-ZIL / WAL-commit sync-write completion->waiter path, NOT core/io_uring.cc. General, deeper.
(d) OSv-SPECIFIC: matched LINUX VU64 (same metal, same raw /dev/nvme1n1 ZFS pool ashift=12/rs=8k/
    sync=standard, 32GiB ARC, io_uring, 200wh) SCALES - sustained ~280-370k commit/15s for the full 6 min,
    qemu 22-27 vCPU CPU-saturated, real NVMe IO, WALWrite oscillating 3-62 (normal contention). NO wedge.
    => NOT a PG/ZFS-on-this-hardware ceiling. It is OSv's cross-vCPU wakeup deficit at the completion->
    waiter layer, surfacing under VU64 concurrency (untested before - the a2a stopped at VU32).

## RELATION TO adaptive-idle-spin: adaptive-idle-spin does NOT and CANNOT fix this. It addresses the
## idle->WAKE latency (an idle vCPU catching a wake in-spin). The VU64 wedge is a lost COMPLETION->WAITER
## wakeup (the ZIL/WAL flush completes but the waiter is never signaled) - a DIFFERENT layer. So:
## adaptive-idle-spin = REAL PARTIAL win (GATE 1 idle-safe + VU32 idle->wake residual addressed);
## the VU64 ZIL-completion lost-wakeup deadlock = the NEXT named residual, deeper, still open.

## LIKELY PRE-EXISTING (not a regression): VU64 was never tested before (a2a capped at VU32). Surfaced now
## because we finally swept past VU32. To confirm: fixed-vs-adaptive VU64 (both wedge = adaptive not the cause).

## THE M1 SCALING PICTURE NOW (honest, measured):
  VU8/16  : OSv FASTER than Linux (a2a: 1.17x / 1.29x)
  VU32    : idle->wake low-mode -> FIXED by adaptive-idle-spin (idle-safe, default-on-able, master PR-able)
  VU64+   : NEW OSv-specific PERMANENT lost-wakeup DEADLOCK on the ZIL-commit/completion->waiter path -
            Linux scales here, OSv wedges. The next residual to root-cause + fix. Deeper than idle-spin.

## NEXT ROOT-CAUSE TARGET: the ZIL/WAL sync-write completion -> waiter wakeup in OSv under high concurrency.
## Where does the flush-completion signal get lost so the WALWrite holder never wakes? (The ZIL commit path
## + the condvar/waiter wakeup it drives - bsd/.../zfs zil.c completion -> the OSv cv/wake_record path.)
## Same wakeup-deficit ROOT (IPI-to-halted-vCPU / cross-vCPU signal) as the whole arc, but at the
## completion->waiter layer, and it goes to a HARD DEADLOCK at VU64, not just a latency low-mode.
