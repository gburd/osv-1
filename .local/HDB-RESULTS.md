# HammerDB TPROC-C: OSv vs Linux, PG-on-ZFS, local NVMe, bare-metal m5d.4xlarge (16 vCPU)
# 40 warehouses, rampup 1min + duration 3min, synchronous_commit=on (durable), driven externally.

## Linux/PG16-on-ZFS baseline (bare metal, DB @ 172.31.12.178, driver1)
| VU | NOPM | TPM |
|----|------|-----|
| 8  | 46388 | 106468 |
| 16 | 44577 | 102708 |
| 32 | 45247 | 103447 |
| 64 | (running) | |
Note: Linux plateaus ~45k NOPM at VU8+ (16-vCPU DB box CPU-saturated on TPROC-C, expected).
