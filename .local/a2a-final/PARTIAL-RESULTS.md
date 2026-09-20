# A2A-final PARTIAL results (OSv arm, io_uring, fresh-boot-per-cell)

OSv, io_method=io_uring, raw /dev/nvme1n1 passthrough, all levers ON, 200wh/19GB.
qemu_cpu ceiling = 3200 (= 32 vCPU * 100). Low qemu_cpu + low NOPM = cross-vCPU wakeup-latency
starvation (guest WAITING, not CPU/IO-bound); high qemu_cpu + high NOPM = healthy.

| VU | rep | NOPM   | p99(ms) | qemu_cpu/3200 | NVMe%util | note |
|----|-----|--------|---------|---------------|-----------|------|
| 8  | r1  | 72277  | 11.98   | 830  | ~24 | |
| 8  | r2  | 86193  | 6.79    | -    | -   | |
| 8  | r3  | 74332  | 18.45   | 841  | -   | |
| 16 | r1  | 173022 | 21.13   | -    | -   | |
| 16 | r2  | 171502 | 6.94    | -    | -   | |
| 16 | r3  | 165372 | 21.39   | -    | -   | |
| 16 | (void) | 51320 | n/a   | -    | -   | HammerDB gather hung 13min; re-ran clean as r2 |
| 32 | r1  | 286453 | 9.81    | -    | -   | healthy |
| 32 | r2  | 231651 | 13.57   | -    | -   | healthy |
| 32 | r3  | 93710  | n/a     | 56   | 43  | LOW-MODE: guest WAITING (0.5 vCPU busy) = wakeup-latency starvation. KEPT, not voided. |
| 32 | r4  | 205234 | 16.00   | 1450 | 70  | healthy |
| 32 | r5  | 195843 | 20.73   | 1350 | 62  | healthy |

OSv VU8  median = 74,332  (72277/86193/74332)
OSv VU16 median = 171,502 (173022/171502/165372)
OSv VU32 median = 205,234 (286453/231651/93710/205234/195843; 4 high-mode 195-286k + 1 low-mode 93k)

SHAPE FLIPPED: prior contaminated run had OSv DECLINING (104k@VU8 -> 65k@VU16 -> WEDGE@VU32).
This clean fresh-boot io_uring run: OSv SCALES 74k -> 171k (+131%) -> 205k (+20%), NO dentry wedge
(#1502 holds end-to-end). The VU32 variance (one 93k low-mode among four 195-286k) is the
cross-vCPU wakeup-latency deficit biting intermittently (confirmed by qemu-cpu discriminator:
low cell = 0.5 vCPU busy = waiting).
VU64 next, then MATCHED LINUX arm.

## LINUX arm (Ubuntu 24.04 glibc, io_uring, ZFS matched, fresh-boot-per-cell)
| VU | rep | NOPM  | p99(ms) |
|----|-----|-------|---------|
| 8  | r1  | 63704 | 9.98    |
| 8  | r2  | 63475 | 10.58   |
| 8  | r3  | 63072 | 10.90   |
Linux VU8 median = 63,475 (very tight ~1% spread)

## PARITY (VU8): OSv 74,332 vs Linux 63,475 -> OSv/Linux = 1.17 (OSv 17% AHEAD)

| 16 | r1  | 135997 | 10.49 |
| 16 | r2  | 133116 | 11.18 |
| 16 | r3  | 131182 | 11.03 |
Linux VU16 median = 133,116
## PARITY (VU16): OSv 171,502 vs Linux 133,116 -> OSv/Linux = 1.29 (OSv 29% AHEAD)

| 32 | r1  | 284092 | 15.08 | qemu_cpu~2000 healthy |
| 32 | r2  | 314463 | -     | qemu_cpu~2050 healthy |
| 32 | r3  | 265056 | -     | qemu_cpu~2090 healthy |
Linux VU32 median = 284,092 (all healthy, CPU-saturated ~20 vCPU; NO low-mode scatter)
## PARITY (VU32): OSv 205,234 vs Linux 284,092 -> OSv/Linux = 0.72 (OSv 28% behind at median)
##   KEY: Linux VU32 shows NO wakeup-latency low-mode (all 3 reps CPU-saturated ~20 vCPU).
##   OSv's intermittent 93k low-mode (0.5 vCPU busy = waiting) is OSv-SPECIFIC = the residual wakeup deficit.
##   OSv high-mode (195-286k) overlaps Linux (265-314k); the median gap is the low-mode drag.
