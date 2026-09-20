# Standing rule: change ONE variable, hold everything else byte-identical (operator directive 2026-09-11)

Otherwise the result is meaningless and the effort wasted. For OSv/PG vs Linux/PG, only the OSv-vs-Linux
part may vary: same PG version, same libc, same warehouses, same GUCs, same io_method, same instance
class, same CPU count, same ARC/cache budget, same quiesce protocol, same driver, same VU levels.

## What this invalidated immediately
The historical Linux number (213,505 @ VU8) is **NOT** apples-to-apples with the OSv runs:
- Linux ran ON bare metal; OSv ran in a KVM guest.        <- hypervisor confound
- Linux ARC capped 16 GiB (binding); OSv ARC ~32 GiB.     <- 2x cache confound
- (matched: PG 18.6, musl, 200wh, io_method=sync)

So the "4.9x behind" headline is only valid to the extent those two confounds are small, and they are
not obviously small. **A real OSv-vs-Linux number requires re-running Linux in a matched guest with a
matched 32 GiB ARC (or OSv with a matched 16 GiB ARC via #1506's OSV_ZFS_ARC_MAX), not reusing the
metal/16GiB number.**

## Two experiments, each with one variable
1. **ZIL A/B (running now, agent fb4ad66f):** independent variable = OSV_ZFS_HIRES_CV (fix on/off).
   Everything else identical on one image. Answers: does the ZIL commit window matter for throughput?
   ARC=32 GiB is fine here because it is HELD CONSTANT across both arms.
2. **OSv-vs-Linux (future):** independent variable = the OS. Requires matching hypervisor AND ARC.
   #1506 (OSV_ZFS_ARC_MAX) is the tool that makes the ARC matchable. Until that PR is on the bench base,
   the honest move is to cap OSv's ARC to Linux's 16 GiB, or run Linux with a 32 GiB ARC to match OSv.

## Tools now in place for matched comparisons
- **#1506 OSV_ZFS_ARC_MAX**: set OSv's ARC ceiling to any value, to match another system's cache.
- **#1505**: ports the ZIL hires fix to master (the bench base already has it by another route).
- **bench/zil-hires-ab-v2**: same-binary A/B switch for the ZIL fix (OSV_ZFS_HIRES_CV).
- **Quiesce protocol**: CHECKPOINT-to-<1s before every cell, both durations recorded.
