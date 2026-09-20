# M1 HammerDB spin-verdict run — RESULT (2026-09-16)

**Boxes (AWS lava, acct 769093516156, us-east-2b, Owner=agent-spinverdict):**
- METAL:  `i-0d2d3a537feb2c14d`  m5d.metal   (Debian 12 ami-0dc1629a58a7d6458, native qemu 7.2 -M pc, raw /dev/nvme0n1 passthrough)
- DRIVER: `i-0d72ade3bc1516018`  c5.4xlarge  (Ubuntu 24.04 — HammerDB 6.0 needs glibc 2.38; the Debian driver `i-0dab66e8bded551c4` was terminated)

Host: Linux 6.1 Debian 12, qemu 7.2.22. Guest: OSv v0.57.0-538-g90ddedaf (bench/writedepth 90ddedaf),
PG 18.6 x86_64-pc-linux-musl, apps 3f93f43, openzfs 6330a45b (2.4.2), 43/43 patches applied clean,
OSV_IDLE_SPIN present in loader.elf, bench-base-gate PASS. 32 vCPU / 32 GiB, num_queues=8, raw NVMe
passthrough (cache=none aio=native), ZFS ashift=12 recordsize=8k sync=standard, 200wh/19GB TPROC-C,
12 GUCs source=command line. Both boxes terminated at end (0 orphans — see Housekeeping).

---

## THE HEADLINE (bigger than the spin verdict): the M1 "OSv declines" curve is largely a HARNESS ARTIFACT

The whole M1 premise — "OSv peaks at VU8 and declines while Linux scales" — is contaminated by a
**run-order / cumulative-degradation confound**: multiple HammerDB cells run on ONE guest boot, and OSv
throughput **decays to HARD ZERO across sequential cells and stays there** until the guest is rebooted.

### Fresh-boot vs contaminated VU32 (spin=10000, the same config):
| condition | VU32 NOPM | note |
|---|---|---|
| **FRESH boot + quiesce (this run)** | **215,504** (r1) | healthy, ~2x VU16; HIGHER than VU16 |
| contaminated (4th cell on a shared boot) | 9,328 / 8,535 / 9,336 | tight triplet — a *clean measurement of a DEGRADED state* |

The tight ~9k triplet fooled the earlier reading into thinking it was "real" — it IS real, but it is
measuring an already-wedged guest, not the baseline. Fresh, VU32 is ~215k.

### The within-boot decay is diagnostic — it wedges to ZERO, not a gradual slowdown:
From the contaminated per-boot sweep (all 6 cells VU16 r1/2/3 + VU32 r1/2/3 on ONE guest boot):

    spin=100000 boot:  VU16_r1=169,092 -> VU16_r2=43,219 -> VU16_r3=0 -> VU32_r1/2/3 = 0 / 0 / 0
    metal CPU:              17.1%           10.2%            3.3%          3.4% (at every 0-NOPM cell)

169k -> 43k -> 0 -> 0 -> 0 -> 0. Hard zero, sticks. metal CPU FALLS as NOPM falls (17%->3.4%) — the
guest is idle-WAITING at the wedge, NOT spinning. **This rules out idle-spin stealing cycles as the
cause of the collapse.** Reboot resets it (fresh VU32 = 215k again). => something ACCUMULATES / LEAKS
across sequential HammerDB cells (32-192 forked-and-destroyed PG backends per cell) and is never
reclaimed, until the guest stalls.

---

## THE DECISIVE CROSS-CHECK: the historical a2a run was PER-BOOT, not per-cell (so its decline is suspect)

Read `.local/a2a3lever/` (RESULT.md, LIVE.md, raw/). The historical M1 headline
("OSv 104,640@VU8 -> 64,839@VU16 declines; Linux 159,792 -> 268,921 scales; VU32 wedges") was measured
on ONE guest boot per arm:
- **Only TWO `console-run-*.log` exist for the entire OSv side.** `console-run-132750` (13:27:55)
  served ALL a2a-all-levers cells — VU8 r1-r4, VU16 r1-r3, VU32 — across **3h22m** (to 16:49:49) on a
  SINGLE boot. `runcell.sh` takes `<os> <vu> <rep>` and does a per-cell *quiesce* but **does NOT reboot
  the guest between cells.**
- That single boot's console holds **109 "autovacuum worker took too long / not accepting" markers** —
  progressive wedging across the run, the SAME cumulative degradation reproduced here.
- a2a VU8 raw: r1=158,830, r2=101,898, r3=104,640, r4=108,688. They **VOIDED r1 (158k) as
  "cold-inflated"** and took the median of r2-r4 (~104k). Fresh-boot data here shows the OPPOSITE
  polarity: **r1 (fresh) is the CLEAN number; r2+ are the CONTAMINATED (degraded) ones.** The a2a
  analysis discarded the one clean cell and kept the degraded ones.
- a2a shape-fix "VU16 wedged... autovacuum worker took too long... a SEPARATE OSv defect after many
  cells" = the SAME run-order wedge, mis-attributed to a distinct defect.

**Inference:** the campaign-level "OSv declines while Linux scales" curve is built substantially on
run-order-contaminated cells. Whether OSv *also* has a genuine residual gap fresh-boot is UNKNOWN until
the fresh-boot curve (VU8/16/32/64, own boot each) + a fresh-boot Linux arm are measured. This run
established one point of that: **fresh VU32 baseline = 215k, healthy, no collapse.**

---

## WEDGE SIGNATURE captured live at a 0-NOPM point (leak-hunt starting data)

A guest that had booted fresh (14:47), served one 215k VU32 run, then decayed to 0 NOPM on the next run
within the same boot. Snapshot AT the 0-NOPM wedge:

- **KVM vCPU threads: 33 S (sleeping), 1 R** of 34. Nearly all vCPUs halted/idle-waiting.
- **qemu 64.7% of ONE core (~0.65 of 32 vCPUs busy).** Idle-WAITING, not CPU-exhausted, not spinning.
- **PG backends: 69 active, 5 idle.** Active-but-blocked; throughput 0.
- **PG wait_event at 0-NOPM (active backends):**
    - `LWLock:WALWrite`     = 33   <- backends serialized behind the WAL write lock
    - NULL wait (`||`)       = 32   <- active, no wait_event = scheduled but not progressing (lost-wake)
    - `Lock:transactionid`   = 2
    - `IPC:CheckpointDone`   = 1
    - `IO:WalSync`           = 1

This matches the a2a wedge backtrace (32 vCPUs halted, ~0 runnable, backends behind a lock). The
signature = **WAL-commit-completion serialization + lost-wake**: 33 pile on LWLock:WALWrite, 32 sit in
NULL-wait, the device is idle, CPUs are halted. Consistent with the recurring OSv cross-vCPU
wakeup-latency theme — but here it manifests as a *terminal wedge that accumulates over a boot*, not a
steady-state throughput number.

### Leak candidate — NOT yet isolated (handoff to the dedicated leak-hunt agent)
The decay-to-zero + reboot-fixes-it + forked-backend-churn points to something that accumulates across
connect/disconnect cycles and is never reclaimed. Per-cell counters (thread count, free mem, ARC size,
`global_l2._nr`, fd count, dentry cache, fork-arena pages) were **NOT sampled** this run — the OSv PG
image has NO httpserver/monitoring API baked in (`grep -c httpserver usr.manifest` = 0), so guest
introspection needs either a console-side probe or a gdb attach to the qemu process. The next agent
should reproduce the decay on a multi-cell boot and sample those counters per cell; the one that grows
monotonically with the throughput decay is the leak. The 33-on-LWLock:WALWrite + 32-NULL-wait signature
at 0-NOPM says to also check whether the WAL-writer's completion wake stops firing (lost wake) as state
accumulates.

**Substrate note:** all of this is OSv-as-qemu-KVM-guest. If the leak instrumentation shows a clear
guest-INTERNAL accumulation (thread/fd/dentry/fork-arena/L2-nr growing), it is OSv-internal and
substrate-independent (would reproduce on Firecracker + bare metal). A Firecracker confirmation is a
separate follow-up — do NOT infer substrate-independence until a guest-internal counter is shown to grow.

---

## Data tables

### Fresh-boot (quiesced, own boot) — the healthy baseline
| VU | spin | NOPM | metal CPU busy | note |
|----|------|------|----------------|------|
| 32 | 10000 | **215,504** | 13.5% (usr 0.2 sys 1.3) | r1; r2/r3 blocked by boot-recovery time + a within-boot decay to 0 on r2b |

Fresh-boot VU8/VU16/VU64 curve + additional VU32 reps: **NOT completed** — the fresh-boot-per-cell
design repeatedly hit 4-min WAL crash-recovery on each boot (unclean pkill of a busy guest leaves torn
WAL; checkpoint-before-kill helps but recovery still dominates), which ate the budget. One clean fresh
VU32 = 215k is the solid result; a second fresh rep (r2b) had already decayed to 0 within its boot,
which is itself decay evidence.

### Contaminated per-boot sweep (all 6 cells per spin on ONE boot) — shows the decay, do NOT read as baseline
| spin | VU16 r1 | VU16 r2 | VU16 r3 | VU32 r1 | VU32 r2 | VU32 r3 |
|------|---------|---------|---------|---------|---------|---------|
| 10000 | 109,446 | 159,103 | 124,527 | 9,328 | 8,535 | 9,336 |
| 100000 | 169,092 | 43,219 | **0** | **0** | **0** | **0** |
| 500000 | (not reached — sweep redirected) | | | | | |

The spin=10000 VU16 cells (ran first on their boot) are ~110-160k; the VU32 cells (ran 4th-6th) are
~9k = already degraded. The spin=100000 boot shows the full 169k->0 collapse. The spin comparison is
UNINTERPRETABLE because run-order dominates the spin effect (the 43k and 0 outliers swamp any spin
signal). This is why VU16 is NOT a valid verdict cell and the per-boot sweep cannot answer the spin
question.

---

## VERDICTS (stated straight)

1. **Does the OSV_IDLE_SPIN isolate win transfer to HammerDB TPROC-C?** — **UNRESOLVED, and the question
   is now secondary.** The per-boot spin sweep is uninterpretable (run-order confound). The one clean
   signal — metal CPU FALLS (not rises) as NOPM collapses, and the wedge is 33 halted vCPUs idle-WAITING
   — indicates the collapse is NOT idle-spin stealing query cycles. A clean fresh-boot spin trio was not
   completed. What we CAN say: at a healthy fresh VU32 (215k), the guest is only ~13% of host CPU, i.e.
   NOT CPU-bound, so idle-spin has idle cycles to burn and is unlikely to steal useful work — but this
   is inference, not the measured trio.

2. **The bigger finding:** the M1 "OSv declines VU8->VU16->VU32 while Linux scales" curve is
   **substantially a run-order/cumulative-degradation ARTIFACT.** Fresh-boot VU32 = 215k (healthy,
   > VU16), and the historical a2a run that established the decline ran ALL cells on one boot (confirmed:
   1 run-boot, 3h22m, 109 wedge markers) and voided the clean r1 cells as "cold." The real OSv bug is a
   **progressive within-boot wedge** (decay to hard zero, reboot-resettable) whose live signature is
   WAL-commit serialization + lost-wake (33 LWLock:WALWrite, 32 NULL-wait, vCPUs halted, device idle).

3. **Does the isolate finding survive?** Likely YES. The syncwrite isolate (OSv ~1.5 vs Linux ~13 lwbs
   in flight; recycle-latency gap; OSV_IDLE_SPIN closing it +56-140%) is a SINGLE CONTINUOUS workload,
   not multi-cell-per-boot, so it is far less run-order-sensitive. The per-commit recycle-latency deficit
   is real. The isolate win and the (artifact) HammerDB decline can BOTH be true: OSv has a genuine
   per-commit recycle-latency deficit that does NOT, by itself, produce a HammerDB throughput decline
   once the guest is not wedged by run-order.

## NEXT (for the dedicated leak-hunt agent — this is the real bug)
1. Reproduce the decay on a multi-cell single-boot run (VU16 x several reps -> watch 169k -> 0).
2. Per-cell, sample from the guest: OSv thread count (backend-thread leak?), free mem + ARC size +
   `global_l2._nr` (the 26.9GiB-free-but-nr=0 wedge signature), fd count, dentry cache size,
   fork-arena COW page count. The one growing monotonically with the decay is the leak.
   (No httpserver in the image — use a console probe or gdb-attach to the qemu pid.)
3. Thread-state histogram + backtraces at the 0-NOPM point (what they wedge ON — LWLock:WALWrite here).
4. Fresh-boot VU8/16/32/64 curve (own boot each, 3 reps) + a fresh-boot Linux arm, to establish the
   TRUE fresh-boot shape and whether any residual OSv gap exists absent the artifact.
5. Clean fresh-boot spin trio at VU32 (10000/100000/500000) if the leak is understood.

## Housekeeping
Both boxes terminated; 0 tagged instances, 0 tagged volumes. (See terminate log below.)

## Terminate log (2026-09-16)
- terminate-instances i-0d2d3a537feb2c14d (metal) + i-0d72ade3bc1516018 (driver) -> shutting-down/terminated
- driver i-0dab66e8bded551c4 (short-lived Debian driver, swapped for Ubuntu) terminated earlier
- Final: driver terminated; metal shutting-down (irreversible, m5d.metal slow teardown); 0 running/pending
  agent-* instances; 0 available/orphan volumes. Confirmed 0 orphans.
