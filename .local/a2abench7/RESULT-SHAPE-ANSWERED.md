# The shape question is ANSWERED, and the answer is negative: the fixes did not change it

2026-09-11. Attempt 7, x86_64 QEMU-KVM on `m5d.metal`, on a base carrying **every** fix this campaign
produced. Three settled repeats per cell, quiesced before each, guest never rebooted between cells.

## The measurement

    VU     median  spread     Linux    ratio
     8     43,510   13.4%   213,505    4.91x
    16     39,997    6.4%   397,000    9.93x
    32     36,922   13.6%   510,367   13.82x

    OSv   : 43,510 -> 39,997 -> 36,922   = -15.1% across VU8 -> VU32
    Linux : 213,505 -> 397,000 -> 510,367 = +139% across the same range

**OSv peaks at VU8 and declines monotonically. Linux rises. The fixes did not change the shape.**

Connect probe stays clean throughout (VU16 s1: median 54.8 ms, p99 147.4, **0 samples >=1s, 0 errors**),
which is the point: **the connect/fork path is genuinely fixed and it was not what limited throughput.**

## What this means, stated plainly
The campaign fixed four real defects - the psABI TCB out-of-bounds canary read, the O(PTEs x threads)
fork range scan, the 2 MB large-page split, and the ELF object-cache AS bug. Those were worth fixing on
their own merits and two are upstream PRs. **But none of them was the throughput ceiling.** Connect
latency went from ~117 ms to Linux parity and NOPM did not move: 43.5k here versus 43.4k measured on the
*older, unfixed* base at VU8. **That is a null result for throughput, and it is the most useful thing in
this report** because it eliminates the entire fork/connect path as the explanation for a 5-14x gap.

**M1 parity is not met, and the gap widens with concurrency**: 4.9x at VU8, 9.9x at VU16, 13.8x at VU32.

## Where the remaining gap is NOT
- **Not fork or connect cost** - fixed and measured at parity, with no throughput effect.
- **Not the psABI canary bug** - fixed; a 19 GB schema now builds through hundreds of forks.
- **Not checkpoint contamination** - every cell was quiesced first (checkpoints returning in 0-1s).
- **Not measurement noise** - spreads are 6.4-13.6%, all under the 15% gate.

## Where it plausibly IS, for the next campaign
The strongest remaining candidate is the one this campaign root-caused but never got to measure under
load: **`dentry_hash_lock`, a single global VFS mutex over 32 already-existing buckets**, with 184
PostgreSQL backends observed parked behind it in a wedged-guest backtrace. PRs **#1502** (the AB-BA
deadlock fix) and **#1503** (per-chain locks) exist and are master-eligible, but **#1503's throughput
effect is explicitly unmeasured.** A sweep with `OSV_VFS_DENTRY_PERBUCKET` on and off is the obvious next
experiment, and it is now cheap: the harness in `.local/a2abench7/` works end to end.

Secondary candidate: the **unattributed stall** seen earlier at VU32 - device 15.7% util, `WALWrite` on
only 1-5 of 32 backends, and the guest using ~1.6% of available CPU. Work neither on the device nor on a
CPU. That was never explained.

## Methodology finding worth more than one cell
**A cell run straight after the schema build measures a checkpoint, not PostgreSQL.** The agent's first
two VU8 repeats gave 80,417 and 44,951 (79% spread) because a checkpoint was writing 1,793,759 buffers,
85.5% of `shared_buffers`, 23.4 GB of distance. **Reporting the 80,417 would have shown 2.7x behind
instead of 4.9x - flattering us by nearly 2x.** The agent refused it unprompted and re-ran from settled
state. Quiesce-to-quiescence (drive CHECKPOINTs until one returns fast) is now part of the harness, and
**no prior benchmark in this programme recorded whether it was settled** - so earlier numbers should be
read with that in mind.

## Housekeeping
Agent e0f833b9 completed with its four boxes still running - the fifth agent lost to context
exhaustion. **But unlike the earlier losses, the boxes were reachable and the guest was still serving
on port 5432 with the full verified config**, so I continued the sweep myself rather than discard a
settled, fully-provisioned environment: quiesced, ran VU16 x3 and VU32 x3 using the agent's own
`cell.sh`/`hdb.sh`/`probe.py`, then salvaged 12 raw artifacts to `.local/a2abench7/raw/` and terminated
all four.

    i-0ce983c4cb91921cf  m5d.metal    terminated
    i-031434d1538558de9  c7gd.metal   terminated
    i-06b5f679718f7e389  c5.4xlarge   terminated
    i-02162e8211e14b30f  c5.4xlarge   terminated
    ours still running: 0

One 20 GB unattached volume remains (`vol-0d12161abd705bd1b`, created 15:04, untagged). **Not deleted**:
it is not referenced by any of my instances and was created an hour after mine launched, so it is
ambiguous and this is a shared account. Left per the standing rule.

**aarch64 was provisioned and verified serving but never swept** - the agent ended before its cells ran,
and I prioritised completing the x86 curve since that is what answers the shape question. aarch64's one
confirmed result stands: **zero `__stack_chk_fail` on that arch including through the schema build**,
which empirically confirms the psABI defect is x86-only, as I argued in #1504's comment from source
reading alone.
