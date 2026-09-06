# aarch64 PostgreSQL-on-ZFS under OSv: first working sweep

HammerDB 6.0 TPROC-C, 40 warehouses, on a 32-vCPU / 48 GB aarch64 OSv guest.

## Environment

| | |
|---|---|
| Host | AWS `c7gd.metal` (Graviton3, 64 vCPU, bare metal), AL2023 arm64, KVM |
| Guest | OSv `v0.57.0-508`, `-accel kvm -cpu host -machine virt -smp 32 -m 48G` |
| Build | `arch=aarch64 conf_fork=1 conf_zfs=openzfs fs=ramfs image=open_zfs,zfs,zfs-tools,postgres18-musl` |
| Database | PostgreSQL 18.6, `aarch64-unknown-linux-musl`, gcc 13.3.1 |
| Storage | OpenZFS 5000 pool `pgdata` on a raw 60 G virtio-blk disk (512-logical), `ashift=12 compression=off atime=off recordsize=8k sync=standard logbias=latency primacache=all`, mounted `/data` |
| PG config | `shared_buffers=8GB max_connections=400 max_wal_size=16GB checkpoint_timeout=1h max_files_per_process=200 autovacuum=on` |
| Scheduler | `OSV_WAKE_PULL=1` |
| Driver | HammerDB 6.0 **ARM64 native** (`HammerDB-6.0-Prod-Lin-RHEL9-ARM64`), run on the host, driving the guest over TCP |
| Base | `wip/aarch64-p2`, which is **24 commits behind `upstream/master`** |

Boot time to userspace: ~250-300 ms.

## Results: TPROC-C, 40 warehouses, 1 min rampup + 3 min measured

`pg_timeprofile false` for all rows in this table (see the caveat below - the
profiler badly distorts results, so only profiler-off numbers are comparable).

| VU | NOPM | PostgreSQL TPM |
|---:|---:|---:|
| 8 | 38,662 | 89,269 |
| 16 | **323,659** | 746,022 |
| 32 | 203,959 | 471,423 |
| 64 | 51,595 | 119,242 |
| 96 | 227,562 | 521,787 |
| 128 | *no result - guest died, reproducible* | |

Peak: **323,659 NOPM at VU16**.

### xtprof distorts the numbers badly

The same VU points measured with `pg_timeprofile true` came out far lower, so
the two settings cannot be mixed in one table:

| VU | NOPM with xtprof | NOPM without xtprof | ratio |
|---:|---:|---:|---:|
| 8 | 208,970 | 38,662 | 5.4x *higher* with |
| 16 | 86,402 | 323,659 | 3.7x lower with |
| 32 | 66,759 | 203,959 | 3.1x lower with |
| 64 | 57,344 | 51,595 | comparable |

The VU8 pair is inverted relative to the others, and the run-to-run spread at
fixed configuration is large. Treat all single-run numbers here as indicative;
they are not medians of repeated runs.

## Comparison to x86_64 - INDICATIVE ONLY

Reference x86_64 figures (same 40wh HammerDB TPROC-C, 32-vCPU guest, WAKE_PULL on):

| VU | x86_64 NOPM | aarch64 NOPM (this run) |
|---:|---:|---:|
| 16 | ~169,000 | 323,659 |
| 32 | ~248,000 | 203,959 |
| 64 | ~27,000 | 51,595 |
| 128 | ~25,000 | crash |

**Do not read this as "aarch64 is faster".** Caveats, in order of importance:

1. **Different bases.** The x86 numbers and these aarch64 numbers were measured
   on two branches that both differ from `upstream/master` and from each other -
   this base carries the whole aarch64 stack (build ports, split-TTBR fork-COW,
   timer-park) plus the three kernel fixes below. A rebase onto current master
   (planned separately) is what will produce authoritative numbers.
2. **Single runs, not medians.** The xtprof table above shows the run-to-run
   spread at fixed configuration is comparable to the aarch64-vs-x86 gap being
   claimed, so most of this table is inside the noise.
3. **Different hardware**, obviously: Graviton3 bare metal vs whatever the x86
   runs used.
4. **Profiler state may differ** between the two sets. These aarch64 rows are
   profiler-off; if the x86 rows were profiler-on, the comparison is invalid on
   that ground alone.

The one thing the shape of both curves agrees on: throughput does **not** scale
monotonically with VU, and there is a hard fall-off at high VU on both
architectures.

## Durability: crash recovery on ZFS works

After a guest crash at VU128, restarting PG on the same pool replayed WAL and
recovered cleanly, with all data intact:

```
LOG:  checkpoint complete: wrote 672126 buffers (64.1%), wrote 119 SLRU buffers;
      0 WAL file(s) added, 0 removed, 664 recycled;
      write=350.218 s, sync=0.005 s, total=350.273 s;
      distance=10894772 kB, lsn=4/B3FBAD98, redo lsn=4/B3FBAD98
LOG:  database system is ready to accept connections
```

`select count(*) from warehouse` returned 40 afterwards. Recovery took ~210 s.

## Open issue: VU128 kills the guest

Reproducible: at 128 virtual users the guest dies (no serial output, QEMU exits;
the host is fine). It survived VU96 in the same session. Not diagnosed - a
64-vCPU-guest retest and a gdb capture at the moment of death are the next
steps. This is what the sweep bottoms out on, and it is worth a bounded
investigation because it may be a fourth generic aarch64 bug.

## Kernel fixes this sweep depended on

All three are generic aarch64 OSv bugs, independent of PostgreSQL, and none of
them is specific to this workload:

1. **`aarch64: cover all of physical memory in the temporary phys map`** -
   `setup_temporary_phys_map()` aliased the phys_mem windows onto the boot
   identity L1 table, which only covers PA 0-4 GB, so any guest with more than
   3 GB (RAM is based at 1 GB on `virt`) faulted in
   `free_initial_memory_range()` before the exception vectors were usable.
   Without this, a 48 GB guest was impossible.
2. **`aarch64: do not cap GICv3 SGI targets at 16 CPUs`** - `max_sgi_cpus = 16`
   sized `_mpids_by_smpid` and `send_sgi()` asserted on it, so any guest with
   more than 16 vCPUs died on the scheduler's first IPI. Without this, 32 vCPU
   was impossible.
3. **`aarch64: satisfy early /dev/random reads from RNDR (FEAT_RNG)`** - the
   postmaster's first `read(/dev/urandom)` blocked forever in
   `randomdev_block()`, because the RDRAND escape hatch in `random_read()` was
   `#ifdef __x86_64__`. This is why aarch64 PG never started while the identical
   image worked on x86. Without this, PG could not serve at all.

## Build-system note (not a kernel bug)

With `fs=ramfs` and `conf_zfs=openzfs`, `$(out)/bootfs.bin` fails on
`FileNotFoundError: 'libzfs_core.so'`. In the top-level `Makefile`, `bootfs_dep`
adds the ZFS userspace set only for `fs=zfs`:

```make
bootfs_dep := scripts/mkbootfs.py $(bootfs_manifest) $(bootfs_manifest_dep) $(out)/libenviron.so
ifeq ($(fs),ext)
bootfs_dep += $(out)/modules/libext/libext.so
else
ifeq ($(fs),zfs)
bootfs_dep += $(tools:%=$(out)/%) $(out)/libsolaris.so
endif
endif
$(out)/bootfs.bin: $(bootfs_dep)
```

`fs=ramfs` therefore gets neither `$(tools)` nor the openzfs `.so` set, while
`modules/zfs-tools/usr.manifest` still names `libzfs_core.so`, `libzutil.so`,
`libshare.so`, `libtpool.so`. `bootfs_dep` should include the ZFS `.so` set and
`$(tools)` for any `conf_zfs=openzfs` build, not only `fs=zfs`.

Second trap in the same area: there are two `$(out)/zpool.so` rules (the
OpenZFS one and the legacy `bsd/cddl` one). Pre-building `zpool.so` without
`conf_zfs=openzfs` on the command line silently produces the legacy binary,
which then fails at runtime with `failed looking up symbol
zpool_set_history_str`. Any pre-build must pass the same flags as the real build.
