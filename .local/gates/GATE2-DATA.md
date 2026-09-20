# Gate 2 measured data (Owner=agent-gates, hotdog 585335547908, us-east-2a) — LIVE, pre-final

## Boxes: METAL i-07cd70356cef08c3a (m5d.metal), DRV i-0d81859ea71589291 (c5.4xlarge)

## io_uring confirmed ACTIVE both arms (show io_method => io_uring, OSv PG rebuilt --with-liburing, 22 io_uring syms)

## OSv adaptive-v2 VU32 (fresh-boot-per-cell, all levers, io_uring) — MEASURED NOPM
| rep | NOPM   | qemu-cpu discriminator (pct-of-one-core, ceiling 3200=32vCPU) | note |
|-----|--------|--------------------------------------------------------------|------|
| r1  | 246458 | during_run_median 2296 (n_hi=99)  | healthy, CPU-saturated |
| r2  | 229755 | during_run_median 2305            | healthy, CPU-saturated |
| r3  | 186862 | during_run_median 2282            | healthy, CPU-saturated |
| r5  | 180014 | during_run_median 2260            | healthy, CPU-saturated |
| r4  | (void) | HammerDB gather-hang (VUCOMPLETE_AFTER 360s, NVMe=0, no TEST RESULT) — harness artifact, not OSv low-mode |
OSv adaptive VU32 median (4 healthy reps) = 208,309 NOPM. ALL 4 healthy reps CPU-saturated (~23 vCPU),
NONE showed the 0.5-vCPU-waiting low-mode.

## Linux VU32 / VU64 (matched: same m5d.metal, same raw /dev/nvme1n1 ZFS pool ashift=12/recordsize=8k/
## sync=standard, 32GiB ARC, io_uring, same 200wh/19GB) — MEASURED NOPM
| VU | Linux NOPM | behaviour (6-min xact_commit-delta sampling) |
|----|-----------|----------------------------------------------|
| 32 | 338265    | sustained ~200-235k commits/15s, CPU-saturated, no wedge |
| 64 | 486112    | sustained ~280-370k commits/15s for full 6 min, CPU-saturated 22-27 vCPU, NO wedge |

## OSv/Linux ratio at VU32: 208309 / 338265 = 0.62 (OSv trails; consistent with a2a's 0.72 - my Linux
## ran warm-cache continuous here, not fresh-boot, so its VU32 is higher than a2a's 284k fresh).

## VU64: THE WEDGE (fully characterized) — see VU64-WEDGE-evidence.txt
OSv VU64 (adaptive AND fixed, io_uring AND worker) all hit a TRUE lost-wakeup DEADLOCK on the WAL-commit/
ZIL-completion path: healthy ~60s (~110k commits/15s) then PERMANENT wedge (commit_delta=2, NVMe=0,
qemu idle ~45%) for 5 min, never recovers. Linux on the identical stack SCALES to 486k NOPM, no wedge.
=> OSv-SPECIFIC cross-vCPU wakeup deficit at the completion->waiter layer, NOT io_uring-specific, NOT
adaptive-caused, NOT a PG/ZFS-on-HW ceiling. Adaptive-idle-spin (idle->wake layer) cannot fix it.

## In progress: VU32 fixed-vs-adaptive A/B (does fixed-10000 reproduce the 0.5-vCPU low-mode here?).
