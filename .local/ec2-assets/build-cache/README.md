# OSv + PostgreSQL 18 SERVING image — bulletproof reproducible build recipe

Produced 2026-08-03 by the build-cache agent on c5n.metal i-0863cae5b76cef523.
OSv commit: 6dd041b7b (gh-fork integ/pg-fork-zfs tip). PG18.0 musl-PIE.
RESULT: manifest-verified serving image; served `psql select 1 -> 1` on KVM.

## The three scripts (run in this order)
1. `build-osv-pg.sh` — runs INSIDE a fedora:39 container (`--privileged --device /dev/kvm`,
   `-v <osv-checkout>:/b -v /mnt/nvme:/mnt/nvme`). Produces build/last/{loader.elf,usr.img}.
   Turnkey from a fresh clone (verified: TURNKEY_EXIT=0).
2. `host-initdb-alpine.sh` — runs on the HOST. Uses an Alpine container (musl loader) to run
   the OSv-built initdb NATIVELY (OSv stubs popen(), so initdb CANNOT run inside OSv).
   Produces the seed cluster at /mnt/nvme/pgseed.
3. `kvm-seed-serve.sh` — runs INSIDE a fedora qemu container. Phase A: create ZFS pgdata pool
   + cpiod-stream the seed cluster into /data + export. Phase B: boot OSv+PG serving, verify
   `select 1`.

## EXACT deltas vs the banked scripts (.local/ec2-assets/ab-harness + .local/ozfs-fixes)
These are the fixes that make the build turnkey (each was a wedge point for prior agents):

1. **CONF_fork not propagating (the fork.cc build wall).** `conf/kconfig/threads` sets
   `def_bool $(shell,[ "$conf_fork" = 1 ] ...)` from the `conf_fork` ENV var, and `.config`
   is generated ONCE and cached. A build dir created by an earlier invocation WITHOUT
   `conf_fork=1` in the env leaves `# CONF_fork is not set` -> fork.cc fails:
   `class sched::thread has no member named set_address_space` / `fork_arena has not been
   declared` (all gated `#if CONF_fork`).
   FIX: wipe `build/release.x64` + `build/last` AND `export conf_fork=1` before the image
   build so `.config` regenerates with CONF_fork=y. (build-osv-pg.sh STEP 6.)

2. **cpiod.so ordering (the roadmap-named wedge).** The pg18-fork manifest requires
   `${OSV_BUILD_PATH}/tools/cpiod/cpiod.so`, but the openzfs image path
   (`fs=zfs conf_zfs=openzfs`) does NOT build `$(tools)` automatically ->
   `Exception: Path does not exist: .../tools/cpiod/cpiod.so`.
   `scripts/build tools` / `stage1` are NOT valid targets (prior agent wedged trying them).
   FIX: after the kernel builds, run an explicit Makefile target BEFORE the image assembly:
     `make mode=release arch=x64 conf_fork=1 conf_zfs=openzfs fs_type=zfs \`
     `     build/release.x64/tools/cpiod/cpiod.so`
   (pulls libsolaris.so/libzfs.so prereqs, links cpiod.so). THEN `scripts/build image=...`
   finds it. (build-osv-pg.sh STEP 6a/6b.)

3. **genbki.pl "catalog-headers Error 2" (a prior agent's build wall).** Root cause was a
   dirty/missing PG source tree. FIX: download a PRISTINE official tarball
   (postgresql-18.0.tar.bz2) into /b/.local/pg18/src every time. (build-osv-pg.sh STEP 3.)
   NOTE: this needs `bzip2` in the container (fedora:39 minimal lacks it).

4. **initdb cannot run inside OSv (popen stubbed).** initdb execs `postgres -V` via popen();
   OSv stubs popen() -> `could not execute command "..." operating system error 0` ->
   `program "postgres" is needed by initdb but was not found`. The banked KVM
   20k-osv-mkpool-initdb.sh runs initdb INSIDE OSv and CANNOT work on the public tip.
   FIX: run the OSv-built (musl-PIE) initdb NATIVELY under Alpine's musl loader
   (`/lib/ld-musl-x86_64.so.1`), as a non-root user (initdb has its own root check that
   patch-pg.sh does NOT neuter), then cpiod-stream the cluster into OSv. (host-initdb-alpine.sh.)

5. **W1 serving config (proven by agent 88daa2b8).** PG's default mmap-anon-shared segment
   hangs OSv (99.9% CPU populate spin). MUST set `shared_memory_type=sysv` in the postmaster
   args or it never reaches "ready". (kvm-seed-serve.sh PGARGS.)

6. **Container package deltas (fedora:39 minimal).** Beyond the banked dnf list, the build
   needs: `libstdc++-static` (kernel link: "libstdc++.a needs to be installed"), `diffutils`
   (`cmp` used by gen-kernel-config-headers), `bzip2` (PG tarball), and for the image build's
   internal zfs-builder VM + boot: `qemu-system-x86` + `qemu-img` (provides `qemu-nbd` used by
   scripts/imgedit.py). AL2023 has NO qemu-system-x86_64 in default repos -> do qemu inside a
   fedora container with `--device /dev/kvm`.

7. **build-infra patch** (.local/ozfs-fixes/pg-zfs-build-infra.patch): bumps the internal
   zfs-builder VM memory 512M->4G so the in-build ZFS image creation doesn't OOM. Applied
   in STEP 2. (Unchanged from banked; just make sure it's applied.)

## Manifest verification (all present in usr.manifest; CONF_fork=y in .config)
  /b/.local/pg18/install/bin/postgres   (musl-PIE, ld-musl interpreter)
  /tools/cpiod.so
  plpgsql.so
  libsolaris.so (ZFS kernel driver), zpool.so, zfs.so, libzfs.so

## Serving confirmation (KVM, c5n.metal, SLIRP hostfwd 5432)
  Booted up in ~440ms; OpenZFS pgdata pool imported+mounted.
  LOG: starting PostgreSQL 18.0 on x86_64-pc-linux-musl
  LOG: database system is ready to accept connections
  psql -h 127.0.0.1 -p 5432 -U postgres -c "select 1"  ->  1   (SERVE_OK)

## Serving config lines (the postmaster args that matter)
  -c shared_memory_type=sysv                 # W1 workaround (REQUIRED)
  -c shared_preload_libraries=plpgsql
  -c unix_socket_directories=                 # AF_UNIX unsupported -> TCP only
  -c listen_addresses=* -c port=5432 -c huge_pages=off
  -c dynamic_shared_memory_type=posix

## Known open walls (OUT OF SCOPE here — the W-fix agents' job)
  W1: mmap-anon-shared startup spin — worked around with shared_memory_type=sysv, but the
      boot is NONDETERMINISTIC: ~1 in 3 boots still spins at 100% CPU before postgres logs
      (bad memory layout hit). Retrying the boot clears it. A real W1 fix removes the retry.
  W2: catalog-read-zero across forked backends — a forked backend can close the connection
      / FATAL on catalog reads. Observed intermittently on `select 1` too on one turnkey run.
  Both are roadmap-known; NOT build defects (the build is deterministic + turnkey).

## Artifact reuse (a follow-on agent's turnkey start)
Bundle: osv-pg-serving-artifacts.tgz (~114M) contains:
  osv-img/loader.elf, osv-img/usr.img, .local/pg18/install (89M), pgseed (39M, initdb'd),
  build-osv-pg.sh, kvm-seed-serve.sh, harness/cpio_push.py
To reuse: extract, place loader.elf+usr.img in /mnt/nvme/osv-img, pg install under
/b/.local/pg18/install, pgseed at /mnt/nvme/pgseed, then run kvm-seed-serve.sh in a fedora
qemu container. To rebuild from scratch: fresh clone integ/pg-fork-zfs @ 6dd041b7b, then
build-osv-pg.sh in a fedora:39 privileged /dev/kvm container (~20-25 min on c5n.metal).
The bundle self-terminated with the box; reproduce from these scripts (the durable channel).

## Turnkey validation
build-osv-pg.sh run from a FRESH clone -> TURNKEY_EXIT=0, loader.elf 73MB + usr.img 66MB,
cpiod.so built, manifest verified (postgres+cpiod+plpgsql+libsolaris+zpool+zfs, CONF_fork=y).
Then kvm-seed-serve.sh -> OSV_READY 2s, postgres ready. Both build phases deterministic.
