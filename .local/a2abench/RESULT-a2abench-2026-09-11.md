# a2abench run: STOPPED by burner-account expiry. Substrate recipe survives; 0 NOPM cells.

## RESOLVED - no action needed on the instances
**The `bene` account (292759875395) was a burner with a hard expiry of 2026-09-11 12:03:00
UTC. It expired on schedule.** Confirmed by the account owner after the fact. There are no
credentials to restore, no path to the account from any other local profile, and therefore
**no orphan to clean: the four instances die with the account, and billing stops with the
account rather than with the instances.** Do not spend time on them.

For the record, the four boxes running at cutoff (all tagged `Owner=agent-a2abench`):

    i-0126a936629a68911   m5d.metal     a2abench-x86-m5d    18.224.44.60
    i-09744de8dee537964   c7gd.metal    a2abench-arm-c7gd   13.59.103.7
    i-01a9667ad35f58299   c5.4xlarge    a2abench-drv-x86    3.143.7.47
    i-09dfc1589c8eb9c2c   c5.4xlarge    a2abench-drv-arm    52.15.179.79

Successor burner is `lava` (769093516156), which at time of writing has an effective quota
of **32 vCPU with another project consuming all 32** - no metal instance fits and there is
no `/dev/kvm`. **No arm of this benchmark can run anywhere until a 32 -> 640 quota increase
lands.** Nothing in this file is actionable until then.

## THE ONE POSITIVE RESULT: the TCB fix holds under real production-shaped load
**This answers a question that was open across five previous attempts.** On base
`cbbf74e7` the guest built a **200-warehouse / 19 GB TPROC-C schema with no
`__stack_chk_fail` abort** - not a microbenchmark, but many hundreds of cumulative backend
forks under a real HammerDB schema load, where the old defect aborted after **1-5** forks.
Every build vuser reported `FINISHED SUCCESS`.

Everything that gates a trustworthy number was verified before load:

| gate | result |
|---|---|
| base guards (`stack_guard` / `OSV_FORK_RANGE_BS` / `OSV_FORK_LARGE_SHARE`) | **3 / 2 / 2** |
| apps pin, `.PHONY: module build` count | `5cb19033`, **1** (re-checked after submodule update) |
| image size (PG-free signature is ~8 MB) | **118,685,696 B = 114 MiB**, `/usr/bin/postgres` = 50,028,736 B |
| OpenZFS vs legacy bsd_zfs | **302** open_zfs objects, **0** bsd zfs objects |
| ZFS pool geometry, via `zpool get` not `zfs get` | **ashift=12** + all 7 properties `local` |
| PGDATA backing | ZFS -> `/dev/vblk1` -> `/mnt/nv/pgdata.raw` -> XFS on NVMe instance store, **no tmpfs** |
| all 12 mandated GUCs, read externally from the driver | **`source=command line`**, incl. shared_buffers 16 GB, max_wal_size 64 GB, fsync/synchronous_commit/autovacuum **on** |
| runtime fork flags, from the console | `OSV_FORK_RANGE_BS default 1`, `OSV_FORK_LARGE_SHARE default 1` |
| PG version | **18.6**, `x86_64-pc-linux-musl`, `io_method=sync` |

**And the thing this run existed to answer is still unanswered: zero NOPM cells completed,
so whether the fixes change the SHAPE or only the LEVEL is unknown. No estimate is given.**

## What happened
At 12:30-12:33 UTC, mid-benchmark (first VU8 cell in flight), simultaneously:
- every `aws` call on profile `bene` began returning `InvalidClientTokenId` /
  `AuthFailure` ("The security token included in the request is invalid")
- SSH and even ICMP to all four instance public IPs began timing out

Not workstation-side network: github.com:22, ec2.us-east-2.amazonaws.com:443 and general
egress all still work from this workstation, DNS resolves, clock matches AWS's `Date`
header exactly (no skew). `~/.aws/credentials` was last modified 08:35, before the run
started, and its `bene` key id is unchanged (`AKIAUIKO...UDMP`) - so the local file was not
rewritten under me; the key was invalidated server-side, or the whole account/IAM user was
disabled.

Profile survey: of 10 local profiles only `lava` still authenticates, and it is a
**different account** (769093516156); it sees zero `Owner=agent-a2abench` instances, so it
cannot reach or clean up these boxes.

The IP unreachability arriving at the same instant as the auth failure suggests an
account-level action (suspension, or an SCP/NACL change), not just an access-key rotation.
**Confirmed afterwards: scheduled burner-account expiry at 12:03:00 UTC.** Every instrument
read correctly. The lag between the stated expiry and the observed failure is credential
caching / propagation, not clock skew - skew was explicitly ruled out against AWS's own
`Date` header, which matched the workstation to the second.

## Result achieved before the cutoff - arm 1 was working
This is real measured output, captured before access was lost.

### Identity (arm 1, x86_64 QEMU-KVM on m5d.metal)
| field | value |
|---|---|
| osv SHA | `cbbf74e7184033861c25ad47cd37376ede6f0c79` (`gh-fork/fix/tcb-psabi-guards`) |
| apps SHA | `5cb19033555d6d4370da905965016f0adb81e515` (the good pin) |
| ZFS submodule SHA | `6330a45b06d20125de679aae5f63ba14082671ef`, `META Version: 2.4.2` |
| PG branch / version | `REL_18_STABLE` / PostgreSQL 18.6, `x86_64-pc-linux-musl`, gcc 13.3.1 |
| build | `conf_fork=1 conf_zfs=openzfs fs=rofs image=open_zfs,zfs,zfs-tools,postgres18-musl` |
| hypervisor | qemu 8.1.3 in fedora:39, `-M pc -cpu host -enable-kvm`, `-kernel loader.elf` |
| guest | 32 vCPU / 64 GiB, `Booted up in 257.99 ms`, OSv v0.57.0-519-gcbbf74e7 |

Base guards verified on the checked-out tree, in-container, before building:
`stack_guard` in `arch/x64/arch-tls.hh` = **3**, `OSV_FORK_RANGE_BS` in `core/mmu.cc` = **2**,
`OSV_FORK_LARGE_SHARE` = **2**. `PHONY_COUNT=1` re-checked after submodule update.
Guest console confirms both fork fixes armed at runtime:

    FORKFLAG OSV_FORK_TIMING unset, default 0
    FORKFLAG OSV_FORK_RANGE_BS unset, default 1
    FORKFLAG OSV_FORK_LARGE_SHARE unset, default 1

### Image-size gate: PASS
`usr.img` = **118,685,696 bytes (114 MiB)**, 30 usr.manifest entries, `/usr/bin/postgres`
present pointing at a 50,028,736-byte musl binary. Not the ~8 MB PG-free signature.

### OpenZFS proof (build-time, as required - there is no version banner)
    open_zfs objects compiled:            302
    bsd/.../fs/zfs spa*.o:                0
    bsd/.../fs/zfs any *.o:               0
    libzfs_core / libzutil / libshare / libtpool in usr.manifest:  1 / 1 / 1 / 1
Runtime line is `ZFS: OpenZFS 5000 initialized` (SPA_VERSION_STRING = pool format), as you said.

### ZFS substrate, read from the guest
    pgdata  ashift        12        local     <- via `zpool get`, not `zfs get`
    pgdata  recordsize    8K        local
    pgdata  compression   off       local
    pgdata  atime         off       local
    pgdata  sync          standard  local
    pgdata  logbias       latency   local
    pgdata  primarycache  all       local
    pgdata  mountpoint    /data     local
    pgdata  396K   577G   96K   /data
Chain: `/data` (ZFS `pgdata`) -> `/dev/vblk1` -> `/mnt/nv/pgdata.raw` (600 GiB raw file)
-> XFS on `/dev/nvme0n1` = "Amazon EC2 NVMe Instance Storage", 838 GiB. No tmpfs anywhere.
Pool created ONCE in a dedicated seed boot, then import-only (`/zpool.so import -f -N pgdata`
-> `/zfs.so mount pgdata`) for the benchmark boot.

### GUCs verified EXTERNALLY from the driver, all `source=command line`
    autovacuum                    on             command line
    checkpoint_completion_target  0.9            command line
    checkpoint_timeout            900 s          command line
    effective_cache_size          4194304 8kB    command line   (= 32 GB)
    fsync                         on             command line
    io_method                     sync           command line
    log_checkpoints               on             command line
    max_connections               400            command line
    max_wal_size                  65536 MB       command line   (= 64 GB, not the baked 1GB)
    min_wal_size                  2048 MB        command line
    shared_buffers                2097152 8kB    command line   (= 16 GB, not the baked 128MB)
    synchronous_commit            on             command line
    data_directory                /data/pg       override
The baked-conf trap you flagged is closed: nothing is at a stock default.

### External driver reachability, proven before load
    select 1, inet_server_addr(), inet_client_addr(), version()
    1|192.168.100.2|172.31.15.150|PostgreSQL 18.6 on x86_64-pc-linux-musl...

### Schema: built successfully
200 warehouses, `count(*) from warehouse` = **200**, `pg_database_size('tpcc')` = **19 GB**
(> 16 GB shared_buffers, so real I/O). All build vusers `FINISHED SUCCESS`.
**No `__stack_chk_fail` abort at any point** - the TCB fix holds through schema build,
which is many hundreds of cumulative backend forks. That is a real positive result on the
central question of whether the base is usable.

### NOPM: NONE. Zero cells completed.
The first VU8 cell was ~8 minutes into its 7-minute window when access was lost. No
`TEST RESULT` line was ever retrieved. **I have no throughput numbers and will not
estimate any.** The shape question (does the fix change SHAPE or only LEVEL) is unanswered.

## A real bug found and fixed on the way: the "EACCES at depth 2" from your brief
Your brief lists this as "one run hit EACCES at depth 2 under a mounted OpenZFS pool - if
that recurs, diagnose rather than fall back to ramfs". It recurred, I diagnosed it, and it
is **not a ZFS bug at all**:

- `scripts/gen-rofs-img.py:53-55` defines the only three modes the generator can emit:

      DIR_MODE  = int('0x4000', 16)     # S_IFDIR, permission field 000
      REG_MODE  = int('0x8000', 16')    # S_IFREG, permission field 000
      LINK_MODE = int('0xA000', 16)     # S_IFLNK, permission field 000

  and lines **206 / 212 / 219** (`write_dir`) plus **244** (`write_fs`, the root inode)
  assign them **unconditionally**, never consulting the host file's real `st_mode`. So a
  rofs image stores **bare S_IFMT type bits with the 9-bit permission field entirely
  zero**: rofs cannot represent permissions at all.
- `fs/rofs/rofs_vnops.cc:261` (`rofs_getattr`) papers over that with a hardcoded
  `attr->va_mode = 0555`, and `fs/rofs/rofs_common.cc:56` sets `vnode->v_mode = 0555` to
  match. So what a caller *observes* is `0555` for every entry, from a stored value of 0.
- `seed_copy.c` faithfully preserved the observed mode: `mkdir(dst, st.st_mode & 0777)`
  = `mkdir(dst, 0555)`, i.e. a destination directory with **no owner-write bit**.
- The next level down does `open(O_CREAT)`, which in `sys_open`
  (`fs/vfs/vfs_syscalls.cc:131`) calls `vn_access(ddp->d_vnode, VWRITE)`, and `vn_access`
  (`fs/vfs/vfs_vnode.cc:443`) returns **EACCES** because `(0555 & 0222) == 0`.

So depth 1 succeeded only because `/data` was created by ZFS itself with a sane mode, and
every deeper `mkdir`/create failed. Two layers are implicated: the generator discards modes
(root cause), and `rofs_getattr` invents a read-only-looking one (what made it surface here).

### The fix, verbatim - it exists nowhere else
The box is gone, so this is the only copy. Applied to
`apps/postgres18-musl/seed_copy.c`, two call sites:

```c
/* in copy_file(), replacing:  int out = open(dst, O_WRONLY|O_CREAT|O_TRUNC, mode & 0777); */
	/*
	 * rofs carries NO permission bits: scripts/gen-rofs-img.py stores only the
	 * S_IFMT type bits, and fs/rofs/rofs_vnops.cc:rofs_getattr() reports a
	 * hardcoded va_mode=0555 for every inode. Preserving that mode creates the
	 * destination tree read-only, so the next level's O_CREAT fails EACCES in
	 * vn_access(VWRITE) -- and PostgreSQL rejects a 0555 PGDATA anyway. Use the
	 * modes initdb itself produces: 0600 files, 0700 dirs.
	 */
	(void)mode;
	int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0600);

/* in copy_tree(), replacing:  if (mkdir(dst, st.st_mode & 0777) < 0 && errno != EEXIST) { */
		if (mkdir(dst, 0700) < 0 && errno != EEXIST) {  /* see copy_file(): rofs has no perm bits */
```

After this, `seed_copy /data-seed /data/pg` completed with **zero errors** and PG 18.6
started clean with `data_directory=/data/pg` on ZFS. PostgreSQL requires PGDATA to be
0700 or 0750, so hardcoding initdb's own modes is correct rather than merely expedient.
The deeper defect - that rofs cannot carry permissions - is untouched and worth its own PR.

## Corrections to premises in the brief
1. **`--use-openzfs` is irrelevant to `fs=rofs`.** `scripts/build:340,372` gate it inside
   `create_zfs_disk()` / `create_zfs_filesystem()`, which only run for `fs=zfs`. With
   `fs=rofs`, `create_rofs_disk()` already builds host-side via `gen-rofs-img.py` - no guest
   boot, no cpiod, no 112 MB push. So for the rofs path the flag is inert (harmless to pass).
   `conf_zfs=openzfs` is what actually selects the OpenZFS kernel objects (Makefile:52,788).
   Note this does **not** contradict the brief's warning: on the `fs=zfs` path the brief is
   exactly right that only `--use-openzfs` avoids the cpiod push. The correction is narrower -
   the flag has no effect either way once you choose `fs=rofs`.
2. **`fs=rofs` does not build the ZFS shared objects, so the image build fails.**
   `Makefile:2242-2245` adds `$(tools)` and `libsolaris.so` to `bootfs_dep` **only when
   `fs=zfs`**. Under `fs=rofs` `libsolaris.so`/`zpool.so`/`zfs.so` are never built, yet the
   `zfs`/`zfs-tools` modules still list them in `usr.manifest`, so `gen-rofs-img.py` dies with
   `FileNotFoundError: 'libsolaris.so'` - and `scripts/build` **still exits 0**. Workaround:
   `make <...> build/release.x64/{libsolaris,zpool,zfs,libzfs,libuutil,libzfs_core,libzutil,libshare,libtpool}.so`
   first, then run `scripts/build`. Worth an upstream PR.

   **This is the fifth silent-success build failure in this project** (after the shadowed
   `build` target, the no-op `ext_fsync`, the ramfs PGDATA, and bsd_zfs masquerading as
   OpenZFS). `scripts/build`'s exit code is not a build-success signal - **always gate on
   artifacts**: image size (~114-119 MB for rofs+PG, ~8 MB = PG-free), `usr.img` existence,
   `install/bin/postgres` existence and size, and the open_zfs-vs-bsd_zfs object counts.
   Every check in `build-image.sh` in this directory exists because a build lied about one
   of them.
3. **fedora:39 also needs `flex` and `bison`** (kbuild's kconfig lexer/parser), else
   `make kbuild` fails at `kconfig/lexer.lex.c` - and again `scripts/build` exits 0.
4. **aarch64 additionally needs `pip install distro`** before
   `scripts/download_aarch64_packages.py` will run (it imports `distro`), and that script
   must run or `Makefile:2105` hard-stops on the missing boost sysroot.
5. Confirmed as stated in the brief: apps `5cb1903` + `.PHONY` count 1; `vhost=off`;
   no `--norandom`; static-libs-first dnf transaction; `-M pc`; `loader.elf` for x86;
   qcow2 root disk; `zpool get ashift`; seed_copy strictly after `zfs mount` with no
   ramfs mount over `/data`.
6. aarch64 TCB is 2 words (`arch/aarch64/arch-tls.hh`: `tls_base`, `dtv`), consistent with
   your analysis that the psABI canary defect is x86-only. Not empirically confirmed at
   runtime - the aarch64 image never finished building.

## State of each arm at cutoff
- **Arm 1 (x86 QEMU-KVM)**: fully working. Image built + proven, pool seeded, PG 18.6
  serving on ZFS, GUCs verified externally, 200wh/19 GB schema built, driver reachable,
  first VU8 cell in flight. **0 NOPM cells completed.**
- **Arm 2 (aarch64 KVM)**: image build was still failing/restarting (had just cleared the
  boost-sysroot and ZFS-.so blockers; third build attempt was in flight). Never booted.
- **Arm 3 (x86 Firecracker)**: not started (correctly gated behind arm 1).

## Deviations
- 3 repeats x 5 VU levels x 3 arms: **none of it ran**. Not a methodology choice - loss of access.
- The `seed_copy` fix is an unpushed change to `apps/`, made to get past a real blocker.
- Elapsed at cutoff: ~1h20m, well inside budget. The stop is external.

## The surviving asset: a complete, working substrate recipe in this directory
Every script here ran successfully against real hardware up to the point of account expiry.
The next attempt starts from a working harness, not from scratch.

| file | what it does / why it exists |
|---|---|
| `host-setup.sh` | AL2023 metal bootstrap: docker, largest-non-root NVMe -> XFS at `/mnt/nv`, tap0+br0 in the HOST netns (192.168.100.1/24), DNAT metal:5432 -> guest, clone `osv-1` **with the -1** |
| `build-image.sh` | fedora:39 build: static-libs-first dnf transaction, **flex+bison**, `pip install distro`, aarch64 boost sysroot, **ZFS .so prebuild** (the fs=rofs trap), then `scripts/build`, then artifact gates that do not trust the exit code |
| `boot.sh` | seed vs run boot modes. Seed = create pool once + `seed_copy`; run = **import-only**. `-M pc`, `loader.elf` (x86) / `loader.img` (aarch64), qcow2 root, `vhost=off`, no `--norandom`, static IP, **no ramfs over `/data`**, all 12 GUCs on the postgres command line |
| `hdb.sh` | HammerDB 6.0 build + timed run, **`vucomplete` poll not the deprecated `runtimer`**, xtprof rotated per run |
| `cell.sh` | one cell = connect probe (started after rampup, alone in the timed window) + HammerDB run |
| `probe.py` | fresh-connect probe: n / median / p95 / p99 / max / counts >=1s,>=5s,>=10s |
| `instr.sh` | `iostat -x` %util parsed **by header name** + qemu CPU from `/proc/<pid>/stat` (because `state='active'` is not "on CPU") |
| `drv-setup.sh` | Ubuntu 24.04 driver: psql + **`HammerDB-6.0-Prod-Lin-UBU24.tar.gz`** (the only name that exists) |
| `seedprep.sh` | host-side `initdb` (OSv stubs `popen()`, so in-guest initdb is impossible) |

### Sequence that worked, in order
1. `host-setup.sh` on the metal box; confirm `NVME_OK`, `NET_OK`, `SETUP_DONE`.
2. `build-image.sh <branch> <arch>`; **gate on artifacts, not exit code** (~114 MB image).
3. `boot.sh seed <arch>` once -> pool created, `seed_copy` clean, pool exported.
4. `boot.sh run <arch>` -> PG serving; verify GUCs externally as `source=command line`.
5. `psql -h <metal-private-ip> -c 'select 1'` from the driver **before any load**.
6. `hdb.sh build <ip>` -> 200 warehouses / 19 GB.
7. `cell.sh <ip> <vu> <tag>` per cell, with `instr.sh` on the metal box at VU32 and top VU.

### One deviation from the brief, deliberate and stated
The brief specified `fs=rofs`; that is what was used, and it works, but note it required the
ZFS-.so prebuild workaround above. `fs=zfs` + `--use-openzfs` is the other viable route and
is the one the brief's `--use-openzfs` warning actually applies to.

### Two things to fix before the next attempt
- **Push the `seed_copy` fix into `apps/` and pin it**, so no future run rediscovers the
  EACCES wall. It is reproduced verbatim above.
- Consider PRs for the two upstream defects: rofs discarding permission bits, and
  `fs=rofs` not building the ZFS shared objects it then requires.
