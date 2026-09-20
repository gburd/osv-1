# ZIL hires-cv A/B — progress log

## Setup verified
- OSV_SHA=c96c16a94472a854848adc018dde4e74a57f473b (gh-fork/bench/zil-hires-ab-v2 tip)
- APPS_SHA=3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3
- ZFS_SHA=6330a45b06d20125de679aae5f63ba14082671ef
- Base guards: stack_guard=3, OSV_FORK_RANGE_BS=2, OSV_FORK_LARGE_SHARE=2, PHONY_COUNT=1, seed_copy rofs fix present
- Image: usr.img 114M qcow2 rofs; loader.elf 68M
- ZFSFLAG mechanism (bsd/porting/netport1.cc:139): getenv("OSV_ZFS_HIRES_CV"); ab = (!e||!e[0])?1:(e[0]!='0'); resolved once, printed once.
  ON  (ab=1): cv->wait(nanoseconds(delta_ns))  — honours sub-ms deadline
  OFF (ab=0): ticks = delta_ns/(1e9/hz); cv_timedwait(ticks) — 250us window rounds to 0 ticks
- Pool: ashift=12, recordsize=8k, compression=off, atime=off, sync=standard, logbias=latency — created ONCE, seed_copy 52M cluster in, exported; run boots import -f -N.
- PG 18.6 musl started; all 12 GUCs source=command line verified from driver.

## Console proof the flag binds per boot
- seed boot:  ZFSFLAG OSV_ZFS_HIRES_CV=1 (unset, default)
- run --env=OSV_ZFS_HIRES_CV=1:  ZFSFLAG OSV_ZFS_HIRES_CV=1 (set)   <- "(set)" proves --env reached putenv

## Boxes (Owner=agent-zilab, lava, us-east-2)
- METAL i-035bbc5224b0eecbf m5d.metal   priv 172.31.5.80  pub 13.59.94.13
- DRV   i-01869557eb2764838 c5.4xlarge  priv 172.31.8.64  pub 3.138.116.180

## Plan
VU 8,32,64. Per VU: ON x3 then OFF x3, quiesce before each cell. Reboot to switch arm.
Order chosen: for each VU run all ON repeats, reboot to OFF, run all OFF repeats. State quiesced
before every cell so order is not load-bearing; grouping by arm minimizes reboots (flag read once/boot).

## Cells (appended as they complete)

### on-vu8-r1  = 49100 NOPM  (112879 TPM)
probe: n=300 err=0 median=42ms p99=56ms ge1s=0
NEWORD p99=11.258ms
quiesce: cp1-4 ~120s (dirty from build), cp5 0.077s -> settled

### ON VU8: 49100, 48758, 47459  median 48758  spread 3.5%  (GOOD)

### ON VU32: 38051, 36713, 37012  median 37012  spread 3.6%  (GOOD)
probe r1: n=300 err=0 median=72ms p99=143ms ge1s=0
instr @VU32 ON (r3): iostat %util median 10.5% (7.2-14.7), w_await 0.13ms, aqu-sz 0.21, wkB/s ~83MB/s
  qemu CPU ~400-437% of one core / 3200 ceiling = ~13% of 32 vCPU. Device idle AND CPU idle -> stall elsewhere.

### ON VU64: 33396, 33864, 34416  median 33864  spread 3.0%  (GOOD)

## ON ARM COMPLETE (boot: --env=OSV_ZFS_HIRES_CV=1, ZFSFLAG printed "=1 (set)")
VU8=48758  VU32=37012  VU64=33864  (medians)
Now rebooting guest to OFF arm (--env=OSV_ZFS_HIRES_CV=0).

## OFF ARM boot: --env=OSV_ZFS_HIRES_CV=0, ZFSFLAG printed "=0 (set)"
NOTE: switching arms, an aborted first OFF-boot attempt left 2 QEMU briefly (killed);
clean OFF reboot then did PG crash-recovery (~8min WAL replay, expected after pkill -9).
Data verified intact: 200 warehouses after recovery. ZFS checksums clean, no corruption.
GUCs re-verified identical (all source=command line). Running OFF batch now.

### OFF VU8: r1=115988 [VOID], r2=46452, r3=47836
  *** r1 VOIDED: quiesce log shows only "checkpoint 1: 0.079s" -- a FALSE quiesce.
  r1 ran immediately after the ~8min crash-recovery, which had just checkpointed, so the
  first CHECKPOINT returned fast while a large dirty backlog remained; the run drained that
  backlog -> inflated 115988 (same failure mode a2abench7 documented at 80417). r2/r3 each
  show the correct pattern (cp1-3 ~120s then a sub-1s cp) = genuinely settled.
  Valid OFF VU8 so far: 46452, 47836 (median ~47144). Will add a 4th clean repeat to get 3 valid.

### OFF VU32: 36957, 36979, 36199  median 36957  spread 2.1%  (GOOD)
instr @VU32 OFF (r2): iostat %util median 15.2% (12.1-24.0), w_await 0.13ms, aqu-sz 0.28, wkB/s ~98MB/s
  qemu CPU ~459-485% of one core / 3200 = ~14.5%.
COMPARE VU32: ON 37012 vs OFF 36957 = 0.15% -> NULL so far.

### OFF VU64: r1=32910 (valid, quiesce cp1-5 slow then cp6 0.081s), r2=0 [DUD], r3 blocked
  *** r2 VOIDED: 0 NOPM / 125 TPM. PG stayed healthy (select 1 ok, checkpoints completing);
  the VU64 driver-side run produced ~no transactions (connection-storm hiccup at 64 VU).
  Batch then wedged in vucomplete poll; killed it. Re-running r2b, r3, and a clean VU8-r4
  with a HARDENED quiesce (require 2 consecutive sub-1s checkpoints, not just 1).

## DONE. Both boxes terminated, 0 orphans confirmed.
i-035bbc5224b0eecbf terminated | i-01869557eb2764838 terminated | agent-zilab live=0, volumes=0
Result: NULL. ON~=OFF at every VU (delta +3.4/+0.1/+2.9% <= spread). See RESULT-zilab.md.
