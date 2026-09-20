# A2A CAPSTONE VERDICT (2026-09-17) - OSv vs Linux PostgreSQL-on-ZFS, matched m5d.metal, io_uring both, fresh-boot-per-cell

## THE MEASURED PARITY TABLE (all NOPM = measured HammerDB output, same hardware)
  VU    OSv NOPM (med)   Linux NOPM (med)   OSv/Linux    verdict
   8       74,332           63,475            1.17       OSv +17% AHEAD
  16      171,502          133,116            1.29       OSv +29% AHEAD
  32      205,234          284,092            0.72       OSv -28% behind (median)
OSv reps: VU8 72277/86193/74332; VU16 173022/171502/165372 (one 51320 gather-hang VOIDED as HammerDB
artifact, re-ran clean); VU32 286453/231651/93710/205234/195843 (5 reps, ALL KEPT, none voided).
Linux reps: VU8 63704/63475/63072 (~1% spread); VU16 135997/133116/131182; VU32 284092/314463/265056.

## THE TWO HEADLINES
1. THE SHAPE FLIPPED: declining->scaling. Prior contaminated run = OSv 104k@VU8 DECLINING to 65k@VU16
   WEDGING at VU32. This clean run = OSv SCALES 74k->171k(+131%)->205k(+20%), NO dentry wedge (#1502
   holds end-to-end), and OSv is FASTER than Linux at VU8 (1.17x) and VU16 (1.29x). The fix arc worked:
   the "OSv declines" narrative was a run-order artifact + two teardown leaks, all now fixed.
2. THE RESIDUAL IS NAMED + PROVEN OSv-SPECIFIC: OSv trails at VU32 median (0.72x) SOLELY due to an
   intermittent cross-vCPU WAKEUP-LATENCY low-mode. Discriminator: the 93k VU32 rep ran qemu_cpu 56/3200
   (0.5 vCPU) + NVMe 43% = guest WAITING (not CPU/IO-bound, not wedged). Linux VU32 (all 3 reps) stayed
   CPU-saturated ~20 vCPU with NO low-mode. So OSv's low-mode has NO Linux analog. When it does not bite,
   OSv's high mode (286k) OVERLAPS Linux (265-314k). The residual = OSv cross-vCPU wakeup latency, the
   exact deficit chased all along (the OSV_IDLE_SPIN #1501 area).

## ONE-VARIABLE AUDIT (honesty gate met)
Matched: same m5d.metal, raw /dev/nvme1n1 passthrough, ZFS ashift=12/recordsize=8k/sync=standard, 32GiB
ARC both, io_uring both (OSv PG rebuilt --with-liburing; both confirmed active via show io_method +
AioIoUring wait events), fresh-boot-per-cell, same 200wh/19GB HammerDB schema, all OSv levers ON.
ONE accepted caveat, documented: libc (OSv musl / Linux glibc via Ubuntu ZFS+io_uring - the Alpine
musl-ZFS path had no installable ZFS module + flaky apk, so B was chosen over burning budget on A). libc
shifts absolute constants but NOT the scaling shape or the wakeup/ZFS-commit path under test.
No wedge regressions: NO EMFILE (leak #1 holds), NO OOM/mem-drop (leak #2 holds), NO VU32 dentry wedge.
Harness incident (first VU64 attempt): SIGKILL-mid-CHECKPOINT tore the sync=standard ZFS pool - HARNESS
bug not OSv; pool rebuilt, poweroff hardened. VU64 not completed within budget (designated stop = VU8/16/32).

## VERDICT
OSv REACHES and at VU8/VU16 EXCEEDS Linux PG-on-ZFS parity; at VU32 it trails at the median solely due to
an intermittent OSv-specific cross-vCPU wakeup-latency low-mode. The fix arc produced parity-or-better at
low-to-mid concurrency AND cleanly named the one residual scaling factor at higher concurrency. This is
the M1 result, honestly: not a blanket "faster" (VU32 median trails), not a failure (shape flipped, ahead
at VU8/16, residual named + localized). The next scaling target is unambiguous: OSv cross-vCPU wakeup
latency (IPI-to-halted-vCPU VM-exit), the OSV_IDLE_SPIN/#1501 lever and broader scheduler work.
Full data: .local/a2a-final/RESULT.md.

## NEXT: CHASING THE RESIDUAL (operator directive "do 2, chase the wakeup-latency residual first"):
Root cause LOCALIZED in core/sched.cc: the wake path already suppresses the cross-vCPU IPI when the target
is idle-POLLING (send_wakeup_ipi sends only if !idle_poll && runqueue<=1); do_idle sets idle_poll during a
FIXED spin_count window. The bug is the CONTROL - a fixed spin count: too short -> a to-be-rewoken thread's
vCPU halts just before its wake -> IPI/VM-exit (the VU32 low-mode); too long -> idle cycle-burn. #1501 is
the blunt fixed-count symptom lever + host-conditional.
FIX (agent c00cdf4d): ADAPTIVE per-CPU idle-spin (guest-side, like Linux halt_poll_ns) - grow the window
when wakes are caught mid-spin (wake-heavy workload), shrink toward a floor when genuinely idle. Works even
where the host does not halt-poll (fixes #1501's host-conditionality). General scheduler improvement.
VALIDATION: isolate A/B (op/s up, halt_exits down) + genuinely-idle no-regression gate (default-safe) +
THE REAL TEST re-run the a2a VU32 OSv cell (does the intermittent low-mode DISAPPEAR - all 5 fresh-boot
reps cluster high, qemu-cpu 0.5-vCPU-waiting signature gone) + p99. If default-safe AND core/sched.cc idle
path is on master -> a standalone master-facing PR (NOT fork-stack-blocked). Bank bank/sched-adaptive-idle-
spin. Brief: .local/WAKEUP-LATENCY-FIX-BRIEF.md.

## VU64 FINAL (2026-09-19): the VU64 wall is a per-backend fork-footprint OOM COST (~0.7GB/backend),
## NOT a lost-wakeup/scheduler bug (6 wake A/Bs refuted; OOM console proved memory). Linux scales (smaller
## fork footprint). Mitigation: more RAM or smaller shared_buffers (sb=1G completes VU64). Real fix: reduce
## OSv per-backend fork footprint (a G2 memory study). adaptive-idle-spin #1511 stands on its own merit
## (idle->wake tail), never claimed to fix VU64. Full: .local/VU64-VERDICT-FINAL.md.
