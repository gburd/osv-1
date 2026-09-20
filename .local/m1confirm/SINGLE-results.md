# OSv SINGLE arm (OSV_BLK_MQ_COMPLETE unset) -- boot line: mode=single num_queues=32
# 3 settled repeats per VU, r0 cold-void.

VU8  r0=155832(VOID cold) | r1=102748 r2=103984 r3=111237 -> MEDIAN 103984  (spread 8%)
     NEWORD probe median ~44ms | %util ~24% | qemu ~7.5 vCPU busy
     matches a2a3lever SINGLE VU8 median 104640 (harness reproduces baseline)

VU16 r1=70569 r2=63983 r3=67055 -> MEDIAN 67055  (spread 10%)
     wait: NULL 68-74%, WALWrite 15-19%, WalSync ~5% (WAL-commit-completion serialization signature)
     %util 22-28% | qemu ~11.8/32 vCPU busy
     matches a2a3lever SINGLE VU16 median 64839

DECLINE CONFIRMED: SINGLE 103984 (VU8) -> 67055 (VU16) = -36%

VU32 WEDGE (all 3 repeats 0 NOPM). NOT the dentry deadlock (#1502 present):
  top -H during wedge shows 6 RUNNING threads (not 0-runnable), load 4.26.
  Console: repeating "autovacuum worker took too long to start; canceled" -- postmaster alive,
  PG stops accepting connections. This is the fork/worker-start hang a2a3lever also hit at the
  VU8/16 boundary in its shape-fix run (a SEPARATE OSv defect from the dentry deadlock).
  So SINGLE VU32 is unusable on this substrate. VU64 skipped (would also wedge).
