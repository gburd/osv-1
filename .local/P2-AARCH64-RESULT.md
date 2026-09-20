# P2 result: aarch64 PostgreSQL-on-ZFS works, and three generic OSv bugs fixed

Graviton3 bare metal (KVM), branch wip/aarch64-p2 (based on
wip/aarch64-forkcow-signed, 24 commits behind upstream/master). Box terminated,
0 orphans.

## Three generic aarch64 bugs found, all upstreamed

| PR | Bug | Who it affected |
|----|-----|-----------------|
| #1490 | temporary phys map covered only PA 0-4 GB | any aarch64 guest >~3 GB RAM wedged silently at boot |
| #1491 | GICv3 `max_sgi_cpus = 16` | any aarch64 guest >16 vCPUs died on the first IPI |
| #1493 | `/dev/urandom` blocked forever (RDRAND escape hatch was x86-only) | any aarch64 app reading urandom at startup |

#1493 is the one that explains the whole aarch64 history: the postmaster's FIRST
read of /dev/urandom parked in `randomdev_block()` -> `_msleep()` ->
`thread::wait()` with all CPUs idle, so PostgreSQL never logged a line. The
driver already had the fix for x86 (answer the read from RDRAND when the software
adaptor is unseeded) but it was `#ifdef __x86_64__`. Same image, same app: worked
on x86, hung on aarch64. Fixed with Arm's FEAT_RNG (RNDR/RNDRRS).

#1490's boundary math is what made it conclusive: `virt` bases RAM at 1 GB, so
3 GB of RAM ends at exactly 4 GB (fits the 4-entry boot table) and 4 GB ends at
5 GB (faults) - precisely the observed <=3 GB ok / >=4 GB hang.

## PostgreSQL serves on aarch64 (first ever)

    LOG:  starting PostgreSQL 18.6 on aarch64-unknown-linux-musl
    LOG:  listening on IPv4 address "0.0.0.0", port 5432
    LOG:  database system is ready to accept connections

data_directory = /data (the OpenZFS pool), shared_buffers = 8GB, boot ~250 ms,
32 vCPU / 48 GB guest.

## Sweep (HammerDB 6.0 native ARM64, 40wh TPROC-C)

| VU | NOPM | TPM |
|---:|---:|---:|
| 8 | 38,662 | 89,269 |
| 16 | 323,659 | 746,022 |
| 32 | 203,959 | 471,423 |
| 64 | 51,595 | 119,242 |
| 96 | 227,562 | 521,787 |
| 128 | guest died (reproducible) | |

NOT a claim that aarch64 beats x86. The agent's own caveat, which I endorse: the
xtprof-on/off comparison moved the SAME VU point by 3-5x, so run-to-run spread is
as large as the aarch64-vs-x86 gap. Different bases, single runs not medians,
different hardware. The non-monotonic curve (64 low, 96 high) is itself evidence
of that variance. P0.4's rebase produces the authoritative numbers.

## Bonus: unplanned durability evidence

After the VU128 crash, PostgreSQL replayed WAL and recovered on the same ZFS pool
with all 40 warehouses intact (672,126-buffer checkpoint). That is a real
crash-consistency data point for P5, obtained for free.

## Left undiagnosed (honest)

VU128 reliably kills the guest while VU96 survives. The agent stopped rather than
half-diagnose it. Possibly a fourth generic bug; deserves a gdb capture at the
moment of death. NOTE: this must be re-tested post-rebase first - the P1 agent
proved the same base lacks `ae077860c` (virtio-blk lock inversion under sustained
write load), which is a plausible cause of a high-VU death and is already fixed
upstream.

## Makefile gap (worth its own small PR)

`bootfs_dep` in the top-level Makefile (just above `$(out)/bootfs.bin`) adds the
ZFS userspace set only under `ifeq ($(fs),zfs)`, so `fs=ramfs` gets neither
`$(tools)` nor the openzfs `.so` set - while `modules/zfs-tools/usr.manifest`
still names `libzfs_core.so`/`libzutil.so`/`libshare.so`/`libtpool.so`, so
`mkbootfs.py` dies on `libzfs_core.so`. It should key on `conf_zfs=openzfs`, not
`fs=zfs`.

This is the gap behind the "pre-build the .so set first" workaround we have been
carrying in EVERY build brief for months.

Second trap in the same area: TWO `$(out)/zpool.so` rules exist (openzfs and
legacy bsd/cddl). Pre-building without `conf_zfs=openzfs` silently produces the
legacy binary, which then fails at runtime with
`failed looking up symbol zpool_set_history_str`.

## Retraction by the agent

Its earlier "seed_copy hangs reading /data-seed" report was wrong and it retracted
it: the guest was simply powering off after the last command, proven with
`--noshutdown`. Nothing wrong with ramfs or rofs. The real cause was the
/dev/urandom block (#1493).
