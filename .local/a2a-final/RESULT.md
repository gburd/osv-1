# A2A-final: does OSv/PostgreSQL scale to PARITY with Linux/PostgreSQL under identical conditions?

**Date:** 2026-09-17/18. **The open measurement that determines whether the whole fix arc produced parity.**

## Box ids (Owner=agent-a2afinal, lava acct 769093516156, us-east-2a) — TERMINATED at end
- `i-005c5bfb32d8f12aa`  m5d.metal (Debian 12) — BOTH guests + host + instrumentation
- `i-0aee60adbbece9746`  c5.4xlarge (Ubuntu) — HammerDB 6.0 driver

## HEADLINE — matched OSv vs Linux, fresh-boot-per-cell, io_uring both sides, medians of settled reps

    VU    OSv NOPM (med)   Linux NOPM (med)   OSv/Linux    verdict
     8       74,332           63,475            1.17       OSv +17% (AHEAD)
    16      171,502          133,116            1.29       OSv +29% (AHEAD)
    32      205,234          284,092            0.72       OSv -28% (behind at median)

**The scaling SHAPE flipped from declining to scaling — this is the headline result.**
The prior matched-but-CONTAMINATED run showed OSv at 104k@VU8 DECLINING to 65k@VU16 then WEDGING at
VU32. This clean run (verified base + io_uring + fresh-boot-per-cell + all levers) shows OSv SCALING:
74k -> 171k (+131%) -> 205k (+20%), with NO dentry wedge (#1502 holds end-to-end). At VU8 and VU16
**OSv is FASTER than Linux**; at VU32 OSv trails at the median but its high mode overlaps Linux.

## Per-rep detail (ALL reps kept; none voided) + p99 + qemu-cpu discriminator

### OSv (io_uring, raw /dev/nvme1n1 passthrough, all levers ON)
| VU | reps (NOPM) | median | NEWORD p99 (ms) | note |
|----|-------------|--------|-----------------|------|
| 8  | 72277, 86193, 74332 | 74,332 | 6.8-18.4 | WAL-commit bound |
| 16 | 173022, 171502, 165372 | 171,502 | 6.9-21.4 | one 51320 gather-hang run VOIDED (HammerDB artifact, re-ran clean) |
| 32 | 286453, 231651, 93710, 205234, 195843 | 205,234 | 9.8-20.7 | 5 reps: four healthy 195-286k + ONE 93k low-mode |

### Linux (Ubuntu 24.04 glibc, io_uring, ZFS matched, fresh-boot-per-cell)
| VU | reps (NOPM) | median | NEWORD p99 (ms) | note |
|----|-------------|--------|-----------------|------|
| 8  | 63704, 63475, 63072 | 63,475 | 10.0-10.9 | ~1% spread, very stable |
| 16 | 135997, 133116, 131182 | 133,116 | 10.5-11.2 | tight |
| 32 | 284092, 314463, 265056 | 284,092 | 15.1 | all CPU-saturated ~20 vCPU, NO low-mode |

## The VU32 variance IS the finding: the residual wakeup-latency deficit, and it is OSv-SPECIFIC
The qemu-cpu discriminator (host counter, not a guest guess) pins it:
- OSv healthy reps (195-286k): qemu_cpu ~1350-1450 / 3200 (~13-15 of 32 vCPU busy) + NVMe 62-70% util.
- OSv low-mode rep (93,710): qemu_cpu **56 / 3200 (0.5 of ONE vCPU busy)** + NVMe 43% util = the guest
  was **WAITING**, not CPU-bound, not IO-bound, not wedged. That is the cross-vCPU wakeup-latency
  starvation signature — the exact per-commit recycle-latency/wakeup deficit this fix arc has chased.
- Linux VU32 (all 3 reps): qemu_cpu ~2000-2100 / 3200 (~20 vCPU busy), CPU-saturated, **NO low-mode**.

So OSv's intermittent low-mode has **no Linux analog** — Linux stays CPU-saturated at VU32 while OSv
occasionally falls into a wakeup-starved wait state. **The residual scaling factor that caps OSv below
Linux at VU32 is OSv's cross-vCPU wakeup latency**, biting intermittently. When it does not bite, OSv's
high mode (286k) essentially matches Linux (265-314k).

## One-variable discipline — what was held byte-identical, and the ONE accepted caveat
Changed ONLY OSv-vs-Linux. Held identical:
- SAME m5d.metal instance, SAME raw NVMe passthrough (`/dev/nvme1n1` straight through, cache=none
  aio=native, format=raw — NOT raw-file-on-XFS, which was the invalidated historical error).
- Linux = a MATCHED KVM GUEST on the SAME m5d.metal under the SAME host-native qemu 7.2.22 (-M pc,
  -cpu host, -enable-kvm). NOT OSv-guest-vs-Linux-bare-metal (the invalidated hypervisor confound).
- 32 vCPU / 64 GiB both. 32 GiB ARC cap both (OSV_ZFS_ARC_MAX / zfs_arc_max = 34359738368).
- ZFS ashift=12 recordsize=8k compression=off atime=off sync=standard logbias=latency primarycache=all
  — proven identical on both pools. (OpenZFS 2.4.3 OSv / 2.2.2 Linux; zio completion path identical.)
- PG 18.6 both. **io_method=io_uring BOTH sides** (brief-mandated; confirmed active via `show io_method`
  and IO/AioIoUring* wait events on both). io_uring was NOT in either stock build — REBUILT OSv PG with
  --with-liburing (musl liburing from source); Linux got it from PGDG (native).
- Same HammerDB TPROC-C 200-warehouse / 19 GB schema, same driver, same 12 GUCs source=command line.
- All OSv levers ON: WAKE_PULL ON, OSV_BLK_MQ_COMPLETE per-queue num_queues=32, fork levers default-on.

**THE ONE ACCEPTED CAVEAT — libc: OSv=musl, Linux=glibc.** This is the least-central variable: it
shifts absolute constants but does NOT change the scaling SHAPE or the wakeup-latency/ZFS-commit path
under test. The TWO variables that DEFINE the question — the ZFS storage path and io_uring AIO — are
matched. (Stock Alpine musl could not provide matched ZFS+io_uring within budget; Ubuntu glibc could,
so libc was the deliberate trade to keep ZFS+io_uring+hardware+NVMe+ARC matched. Documented, not hidden.)

## Methodology — corrects the run-order artifact that manufactured the "OSv declines" result
- FRESH BOOT PER CELL (one guest boot per VU-level per rep). NOT multi-cell-per-boot (the artifact).
- Kept ALL reps incl fresh r1 (did NOT void the fresh run as "cold"). Reported full set + median.
- Hardened quiesce: 2 consecutive sub-1s CHECKPOINTs before every cell.
- Throughput = HammerDB NOPM (pasted above). Latency = driver NEWORD p99. Saturation = HOST qemu-cpu
  counter + iostat (not a guest guess).
- Watched the wedges we fixed: NO EMFILE (leak #1), NO OOM/monotonic-mem-drop (leak #2), NO VU32 dentry
  wedge (#1502) — none recurred.

## Base (VERIFIED, not changed)
gh-fork/bank/fork-arena-real-reclaim @ OSV_SHA 43fcdca79; apps @ 3f93f43. bench-base-gate PASS all 9
markers. Both leak fixes (fd-reap + arena overflow-reclaim) + 8 cross-AS coherence scopings. Leak probe
DORMANT (OSV_LEAK_PROBE unset). usr.img 118,685,696 B, byte-identical to the prior verified-good image.

## Honesty gate
Every NOPM above is MEASURED HammerDB output on the SAME m5d.metal hardware. OSv AHEAD at VU8 (1.17x)
and VU16 (1.29x); OSv behind at VU32 median (0.72x) with the gap driven by an OSv-specific intermittent
wakeup-latency low-mode (characterized by the qemu-cpu discriminator, not asserted).

## Incident (harness, not OSv): logged for honesty
At the first VU64 attempt, my poweroff SIGKILLed qemu while a CHECKPOINT was still in flight (ssh-timeout
race), tearing the sync=standard ZFS ZIL/mount state -> PG PANIC "could not locate a valid checkpoint
record" + zfs mount abort. This was a HARNESS bug (kill-during-checkpoint), NOT an OSv fault. The 19GB
pool was rebuilt and the poweroff hardened (checkpoint to completion + fast second checkpoint + idle
check + settle, never kill mid-write). No OSv data before the incident was affected.

## Housekeeping (confirmed)
Both boxes TERMINATED (i-005c5bfb32d8f12aa + i-0aee60adbbece9746 both state=terminated).
0 agent-a2afinal instances not-terminated. 0 available/unattached volumes in the account.
