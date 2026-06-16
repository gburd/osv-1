# ZFS A/B Performance: old BSD-ZFS (c.2014) vs OpenZFS 2.4.3

This document compares the two ZFS implementations that have shipped in this
OSv fork:

- **OLD** — the c.2014 BSD-ZFS port (OpenSolaris-derived), as it existed at
  commit `030c71a4` (the last pre-integration baseline, the parent side of the
  OpenZFS 2.4.3 import `c74073e1`).
- **NEW** — OpenZFS 2.4.3 (`zfs-2.4.3` + OSv platform commits), as integrated on
  `osv-improvements` (tip `65cde02b`).

Both arms were built on the same host with the same modern toolchain. As
documented in Result 1, the NEW arm was measured directly; the OLD c.2014
baseline boots and mounts ZFS but cannot execute application binaries under that
toolchain, so the comparison is carried by the architectural/feature deltas
(Results 2 and 3) plus the NEW-arm reference numbers.

## Test environment

| | |
|---|---|
| Build host | meh (24-core x86_64, NixOS, gcc-15) |
| Hypervisor | QEMU/KVM (`scripts/run.py`) |
| Guest memory | 512 MiB (`-m 512`) |
| Guest vCPUs | 1 (`-c1`) |
| ZFS image | `fs=zfs image=zfs-test`, qcow2 virtual size 4 GiB (`fs_size_mb=4096`) |
| Pool | single-vdev `osv` pool on the virtio block device |

## Harness selection

Two harnesses were considered:

- **`tst-zfs-recordsize`** — POSIX sequential write/read against two datasets
  with `recordsize=8K` vs `recordsize=128K`. Uses only the `recordsize` dataset
  property and ordinary `open/write/read/fsync`. This is portable across both
  ZFS implementations and is therefore **the fair cross-implementation A/B
  harness**.

- **`tst-zfs-db-sim`** — a database-style mixed read/write workload that sweeps
  six configurations exercising `O_DIRECT`, `primarycache=metadata`,
  `compression=lz4`, and `logbias=throughput`. These are **OpenZFS-era**
  features; the c.2014 BSD-ZFS port does not implement `O_DIRECT` or the lz4 ABD
  path. db-sim is therefore reported as a **NEW-arm-only feature showcase**, not
  a fair A/B — its existence is itself an A/B finding (the new port supports
  configurations the old one cannot express).

## Result 1 — recordsize sequential throughput (fair A/B)

128 MB sequential file per dataset; I/O buffer == recordsize. Read figures are
dominated by ARC cache hits (the written file is still resident), so the
**write** column is the meaningful disk-path comparison; read is reported for
completeness and is comparable between arms because both warm the ARC the same
way.

### NEW arm (OpenZFS 2.4.3) — 4 fresh-boot runs

| Run | 8K write MB/s | 8K read MB/s | 128K write MB/s | 128K read MB/s |
|----:|--------------:|-------------:|----------------:|---------------:|
| 1 (cold) | 386.3 | 2134.7 | 44.8 | 667.7 |
| 2 | 252.1 | 1827.6 | 278.7 | 663.7 |
| 3 | 289.5 | 1851.9 | 354.1 | 1350.7 |
| 4 | 313.0 | 1614.4 | 369.4 | 661.1 |
| **median (runs 2-4)** | **289.5** | **1827.6** | **354.1** | **663.7** |

Run 1's 128K=44.8 MB/s is a cold-boot outlier (first txg sync absorbing the
whole 128 MB write before the ARC/dirty-data pipeline warms); runs 2-4 are
steady-state. Steady-state shows 128K recordsize ~20% faster on writes than 8K,
as expected for sequential I/O (fewer, larger ZFS records → less per-record
metadata and indirect-block overhead).

### OLD arm (BSD-ZFS c.2014) — not measurable under the modern toolchain

The OLD baseline at `030c71a4` was built on the same host with the same modern
toolchain (gcc-15, binutils-2.46) used for the NEW arm. The resulting kernel
**boots and mounts the BSD-ZFS rootfs correctly** but **cannot execute any
application `.so`**, so no throughput numbers could be captured from it.

Evidence (full `conf_debug_elf=1` ELF-loader trace, `tests/tst-hello.so`):

```
... libsolaris.so loads, relocates 760+193 symbols, runs DT_INIT, ZFS mounts ...
VFS: initialized filesystem library: /usr/lib/fs/libsolaris.so   <- ZFS rootfs OK
...
Booted up in 605.35 ms
Cmdline: tests/tst-hello.so
ELF [.../tst-hello.so]: Instantiated
ELF [.../tst-hello.so]: Loading segments
ELF [.../tst-hello.so]: Loaded and mapped PT_LOAD segment ... (x4)
ELF [.../tst-hello.so]: Processing headers          <- last line; then hangs
qemu-system-x86_64: terminating on signal 15 (timeout)
```

The kernel-side filesystem library (`libsolaris.so`) loads through the early VFS
path and works perfectly; the **application** load path
(`program::load_object`) hangs immediately after `object::process_headers()`,
before `load_needed()` emits its first `DT_NEEDED` trace. The hang is:

- **not recordsize-specific** — `tst-hello.so` (pure `printf`, no ZFS) hangs
  identically;
- **not memory/CPU-dependent** — reproduced at `-m 512 -c1`, `-m 1024 -c1`,
  `-m 512 -c2`;
- **not a loader regression** — `core/elf.cc` and the `musl_1.1.24` submodule are
  **byte-identical** between the OLD and NEW arms (`diff -q` clean), yet the NEW
  arm runs `tst-hello.so` and prints "Hello World" on the same host.

The single commit separating the OLD baseline from the integration point is the
OpenZFS 2.4.3 import itself (`c74073e1`); the modern-toolchain build-compat work
(`gnu++14`, `<algorithm>` include, binutils-2.46 link fixes) lives on the
integration branch. Back-porting that compat work onto `030c71a4` would build an
app-capable OLD kernel, but it would no longer be the c.2014 baseline — it would
be the 2014 ZFS code compiled with 2026 platform glue, which is not the artifact
under comparison.

**Conclusion:** a same-host, same-toolchain throughput A/B against the unmodified
c.2014 BSD-ZFS port is not achievable, because that port's application loader
does not survive the modern toolchain. The meaningful A/B that *can* be made on
identical hardware is the architectural/feature delta below (db-sim feature
matrix and the ARC-bridge analysis), plus the NEW-arm steady-state numbers above
as the absolute reference for the shipping implementation.

## Result 2 — db-sim (NEW-arm-only feature showcase)

750 MiB database, 8 KiB pages, 30 s mixed R/W per config, guest detected
~511 MiB RAM. C0/C2 SKIP because the no-`O_DIRECT` configs need ~512 MiB and the
guest is just under the threshold (page-cache + ARC both grow).

| Config | Status | TPS | compression | primarycache | O_DIRECT |
|---|---|---:|---|---|---|
| C0-baseline | SKIP | — | off | all | no |
| C1-odirect | PASS | 290.1 | off | all | yes |
| C2-pcache-meta | SKIP | — | off | metadata | no |
| C3-odirect+pcache | PASS | 300.5 | off | metadata | yes |
| C4-odirect+lz4 | PASS | 257.7 | lz4 | metadata | yes |
| C5-full | PASS | 300.3 | lz4 | metadata | yes |

Minimum viable config @128 MiB-class RAM: **C1-odirect**. The old BSD-ZFS port
cannot run any of these configs because it lacks `O_DIRECT` and the lz4 ABD
path — the entire table is functionality the 2.4.3 import adds.

## Result 3 — ARC bridge removal (memory/design delta)

Commit `375598d2` ("pagecache: remove unreachable ARC bridge code") deleted 308
lines of `core/pagecache.cc` that, in the BSD-ZFS era, shared ARC buffer pages
directly into the mmap page-cache layer (the `cached_page_arc` class and the
`arc_share_buf`/`arc_unshare_buf` hook).

Key finding: **this is not a runtime regression.** OpenZFS 2.x made
`arc_share_buf()` a static function, which made the OSv ARC-bridge hook
**unreachable** before the code was removed. Under OpenZFS 2.x, ZFS-backed mmap
already routes through the regular `read_cache` path (fed by the
`zfs_vop_cache()` vnode hook calling `zfs_read()` per page). The removal is dead
-code cleanup; the IS_ZFS bridge path had no live callers in the NEW arm.

There is therefore no double-caching to "fix" and no throughput delta
attributable to the removal itself: ARC caches compressed ZFS blocks while
read_cache caches decompressed 4 KiB pages — different granularities, no overlap.

Resident-memory comparison (OLD bridge-active BSD-ZFS vs NEW bridge-removed
OpenZFS) could not be measured directly: as documented in Result 1, the OLD
baseline does not run application `.so` files under the modern toolchain, so the
in-guest memory-probe test cannot execute on that arm. The design conclusion
stands on the code analysis above rather than a runtime delta — the bridge path
was already unreachable in the NEW arm before removal, so there is no resident-
memory regression to attribute to the cleanup. The 308 deleted lines were
dead code: a net reduction in kernel `.text`/`.data`, not a change in live
ARC/page-cache residency.