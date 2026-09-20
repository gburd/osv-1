# The full re-benchmark is GATED, and I am sequencing rather than launching into a wall

2026-09-10. Two hard facts, both measured before spending anything.

## Fact 1: the benchmark is blocked on a bug still in flight
`__stack_chk_fail` fires after **1-5 cumulative `fork()` calls**, so a TPROC-C run that needs hundreds
of backend spawns cannot complete. Agent `6bc0852a` is diagnosing it now with my shared-`app_tcb`
hypothesis. **Launching benchmark arms before that lands would reproduce the same crash on four boxes
instead of one** - which is exactly what the last four attempts did, each for a different reason.

Confirmed not yet fixed: no commit on any branch gives children a private app TCB.

## Fact 2: capacity does not fit the full matrix right now

    in use: 520 / 640  =>  120 free

    campaign needs ~192 vCPU:
      m5d.metal  (x86 KVM + Firecracker)   96
      c7gd.metal (aarch64)                 64
      2x driver                            32
    fits in 120?  NO

So even if the bug were fixed this minute, the parallel four-arm campaign the user asked for does not
fit. Other projects hold the balance (`libumem-*` alone had two 192-vCPU metal boxes earlier today).

## Therefore: maintenance now, benchmark on the trigger
Dispatched agent `de0d45fd` for the full maintenance sweep, which needs no metal and no working fork:
reviewer comments, the three-way correction audit, dependency currency, upstream-filed status, plan
update, repo sync, and local/LAN/EC2 tidy.

**The benchmark launches when both conditions clear:**
1. `__stack_chk_fail` fixed and validated (agent 6bc0852a), and
2. >=192 vCPU free, or the arms run sequentially on one metal box.

**What is already prepared, so the trigger is cheap to pull:**
- Base `wip/pg-x86-forkroot-largeshare` @ `42aeb163b` - both fork halves, elf fix, rofs+pagecache
  fork-arena fixes. Connect latency already **8.61x better on x86** and at Linux parity on aarch64.
- aarch64 base `wip/forkroot-arm-base` @ `5a8e946f0`.
- Corrected apps pin `5cb1903` (`wip/pg-v26-faultfix-repinned2`), which avoids the PostgreSQL-free
  image trap.
- Optional extra arm: the VFS dentry fixes (#1502/#1503).
- The Linux comparison target is measured and matched (32 logical CPUs on socket 0, musl PG 18.6, ARC
  capped 16 GiB and proven binding): **VU8 213,505 | VU32 510,367 | VU64 614,277 peak | VU96 547,813**.
- Every substrate footgun is written down, including today's: `--use-openzfs` not `conf_zfs=openzfs`,
  `upload_manifest.py` hardcoding `-m 4G`, `fs=rofs` ~119 MB (PG-free ~8 MB), `vhost=off`,
  `zpool get ashift`, no `--norandom`, and `seed_copy` after the `zfs mount`.

## The open question the benchmark exists to answer
Linux **scales** to VU64; the old OSv base **peaked at VU8** and declined. Connect latency is now fixed
on both ISAs, so: **do the fork and VFS fixes change the SHAPE, or only the level?** Ratios must carry
their VU level - a bare "Nx" is meaningless when it quadruples across the sweep.
