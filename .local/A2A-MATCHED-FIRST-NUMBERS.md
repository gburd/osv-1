# First TRUE apples-to-apples OSv-vs-Linux, VU8. The matched gap is 1.52x, not 4.9x.

Agent 99c8421f, in progress. Same m5d.metal, same physical NVMe, same qemu 8.1.3, Linux in KVM (NOT bare
host - hypervisor matched), musl both sides, 32 vCPU / 64 GiB both, ZFS ashift=12/recsize=8k/sync=standard
both, 32 GiB ARC both, all 12 GUCs identical source=command line, 200wh/19GB both. ONE variable: the OS.

## VU8 (settled, cold r1 voided both arms)
    OSv   VU8 median: 104,640  (r2/r3/r4 = 101898/104640/108688, spread 6.5%)
    Linux VU8 median: ~159,318 (r1/r2 = 158843/159792; r3 pending)
    ratio OSv/Linux = 0.66  =>  OSv 1.52x behind at VU8
    OSv NEWORD p99 ~49ms | connect p99 44ms, 0>=1s, 0 err

## Why this is the important number
The OLD Linux baseline (16-vCPU VM, glibc, mismatched) was 213505 and gave a "4.9x behind" gap. This
MATCHED Linux (32 vCPU KVM, musl, 32 GiB ARC, SAME NVMe) is ~159k, and OSv with all levers is 104,640.
So the honest apples-to-apples gap is 1.52x, not 4.9x. The mismatched baseline was DOUBLE-counting a
hardware/libc advantage as an OSv deficit. This is exactly why the "change one variable" directive
mattered - it halved the apparent gap.
Also: OSv VU8 104,640 is 2.2x the pre-fix ~47k on the same base minus the levers, so the campaign's
fixes (fsync guard + fork + TCB + ZIL + WAKE_PULL) delivered a large real gain at VU8.

## The SHAPE question (still resolving - the decisive open item)
OSv DECLINES VU8->VU16 (104640 -> 64839) despite WAKE_PULL ON. VU32 WEDGED (arm-independent substrate
trap): top -H showed ALL 35 qemu threads in S (sleep), 0 R, 0 D -> guest fully halted, NOTHING RUNNABLE.
This CONFIRMS the remaining ceiling is NOT wake-placement (WAKE_PULL has nothing to steal) - it is a
lost-wake / WAL-commit serialization wedge. VU8 wait was WALWrite 31-34%; only 7.7/32 vCPU busy.
Pending: does Linux ALSO decline VU8->VU16 on this exact config (=> workload, OSv at parity in shape),
or scale (=> OSv-specific WAL-commit serialization is the next target)? Linux VU16 sweep next.

## Substrate note
VU32 wedge (guest network died ETIMEDOUT, no OOM, 0 runnable threads) is a lost-wake bug, arm-independent,
seen in prior runs too. It caps the sweep at VU16 on this substrate. It is itself a real OSv defect to
chase (a lost wakeup under load), separate from the throughput question - a backend blocked on a WAL
commit whose completion wake never arrives.
