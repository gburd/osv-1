# Task C (geometry+libc-matched Linux baseline) and Task B (the wedge backtrace)

2026-09-09, agent-fcmetal. Boxes `i-0e4869c1d9417eec8` (m5d.metal) + `i-0e07da1e896ffe492`
(c5.4xlarge driver) **terminated, 0 orphans**. Task A (Firecracker) **NOT REACHED** — stated
plainly, per the standing priority.

Artifacts: `.local/fcmetal-2026-09-09/wedge.tgz` (gdb captures + host instruments),
`runs.tgz` (all HammerDB cells + connect probes).

---

## HEADLINE 1: the old Linux reference understated Linux by 2.3x

The standing reference (99,504 NOPM @ VU8) was measured on a **16-vCPU m5d.4xlarge VM with
glibc**. Matched to the OSv arms (32 logical CPUs, bare metal, musl) it is **232,139 @ VU8**.

Removing the confounds did **not** flatter OSv. It exposed a larger gap.

| VU | Linux (metal, musl, 32 logical) | OSv x86 (prior arm) | ratio |
|----|--------------------------------|---------------------|-------|
| 8  | 213,505 (median)               | 43,407              | 4.9x  |
| 16 | 376,568                        | 37,690              | 10.0x |
| 32 | 510,367                        | 34,789              | 14.7x |
| 64 | **614,277**  <- Linux peak     | 28,377              | 21.6x |
| 96 | 547,813                        | 26,047              | 21.0x |

**The gap widens monotonically with concurrency, 4.9x -> 21.6x.** A single "Nx" figure is
meaningless here; the VU level must be attached.

## HEADLINE 2: "no scaling region on Linux either" was a 16-vCPU artifact

That conclusion is **withdrawn**. It was banked in `LINUX-BASELINE-VERDICT.md` and elsewhere from
a VM with half the CPUs. On matched geometry Linux **scales to VU64 (2.9x its own VU8)**, then
declines modestly at VU96.

**The shape differs, not just the level.** Linux converts added concurrency into throughput up to
VU64. OSv peaks at VU8 and declines monotonically — it converts concurrency into queueing
immediately. Linux's peak sits *beyond* VU32, the point at which the OSv aarch64 arm cannot
complete at all.

### NOPM, 3 repeats, median + min/max, >15% spread flagged

| VU | r1 | r2 | r3 | median | min-max | spread |
|----|----|----|----|--------|---------|--------|
| 8  | 232139 | 213505 | 202187 | **213505** | 202187-232139 | 14.0% |
| 16 | 397160 | 376568 | 329770 | **376568** | 329770-397160 | **17.9% FLAGGED** |
| 32 | 527415 | 510367 | 405561 | **510367** | 405561-527415 | **23.9% FLAGGED** |
| 64 | 627652 | 614277 | 576760 | **614277** | 576760-627652 | 8.3% |
| 96 | 581061 | 378125 | 547813 | **547813** | 378125-581061 | **37.0% FLAGGED** |

Three of five cells exceed 15%. Cause is visible in the checkpointer data below and is **not**
noise: `max_wal_size=64GB` does not stop WAL-triggered checkpoints at this throughput.

### `num_timed`: your 64GB premise does NOT hold at this throughput

    num_timed = 1     num_requested = 18     write_time = 7472 s     sync_time = 7 s

**18 of 19 checkpoints were WAL-triggered, not timed**, even at `max_wal_size=64GB`. At 614k NOPM
the WAL fills far faster than the 15-minute timer fires. The knob worked on the OSv arms (6 timed /
0 WAL-triggered) because they run 20x less throughput — it is not a platform difference.
`write_time/sync_time = 1067x` independently reconfirms on a third configuration that the write
phase dominates and fsync is cheap.

### Connect probe (fresh connection + `select 1`, 1 Hz, alone in the timed window)

| VU | n | median | p95 | p99 | max | >=1s | >=5s | >=10s | NOPM |
|----|---|--------|-----|-----|-----|------|------|-------|------|
| 8  | 300 | 3.8 ms | 5.2 | 19.0 | 231.7 ms | 0 | 0 | 0 | 213505 |
| 16 | 300 | 3.9 ms | 5.9 | 46.4 | 442.7 ms | 0 | 0 | 0 | 376568 |
| 32 | 300 | 4.7 ms | 12.9 | 44.1 | 383.0 ms | 0 | 0 | 0 | 510367 |
| 64 | 300 | 5.5 ms | 9.3 | 22.8 | 411.3 ms | 0 | 0 | 0 | 614277 |
| 96 | 288 | 5.1 ms | 12.4 | 44.3 | 244.8 ms | 0 | 0 | 0 | 547813 |

**Zero probes >=1s at any level**, 4488 samples, 0 failures. Median 3.8-6.8 ms. The OSv aarch64
arm's 262 ms median remains ~50x worse.

NEWORD (VU64, xtprof): CALLS 79587, MIN 0.725 ms, P50 2.079, P75 2.605, P95 4.053, P99 6.506,
MAX 312.747 ms.

### `%util` + wait events — the discriminator, third pattern in the matrix

VU32: `LWLock:WALWrite` on only **1-4 of 32** backends, `IO:WalSync` 1, device **37.6-46.6% util**,
304-414 MB/s writes, aqu-sz ~2.

VU96 (top): `LWLock:WALWrite` **49**, `Lock:transactionid` 22, `IO:DataFileRead` 4, with the device
**71.6-77.0% util**, 452-576 MB/s, aqu-sz 7.9-9.6.

So the matrix now reads:
- **Linux moderate concurrency**: no WAL queue, device ~40% busy.
- **Linux high concurrency**: WAL queue on 49 backends, device **72-77% busy** — the queue is the
  expected consequence of a loaded device.
- **OSv**: the same queue with the device **~98% idle** — an OSv-side cost.

`%util` alongside the wait event remains the discriminator; the lock name alone proves nothing.

---

## How geometry was restricted, and proof it binds

**32 logical CPUs = 16 physical cores x 2 hyperthreads, socket 0.** m5d.metal is 2 sockets x 24
physical x 2 threads = 96 logical, so "32 physical cores on one socket" is arithmetically
impossible; 32 physical would have required 8 cores from socket 1 and imported a cross-socket
confound. Sibling pairs verified (0/48, 1/49, 15/63), not assumed. The OSv guests were given 32
vCPUs on the same hardware class, so both sides are SMT-inclusive counts.

Mechanism: cgroup v2 via docker (`--cpuset-cpus=0-15,48-63 --cpuset-mems=1... =0 --memory=64g`),
**not** kernel `mem=` (needs a reboot; would have capped the other tasks sharing the box). A cgroup
ceiling is also the closer analogue to a guest, which sees a hard limit rather than a smaller machine.

Proof, read from the cgroup files (authoritative) **under load**:

    memory.max            = 68719476736   = 64.00 GiB exactly
    cpuset.cpus.effective = 0-15,48-63    = 32 logical, socket 0
    cpuset.mems.effective = 0             = socket-0 memory only
    memory.peak           = 21772038144   = 20.3 GiB   <- the cap does NOT bind
    mpstat: CPUs 0-15,48-63 at ~74% busy (51 usr / 21 sys / 25 idle), all others idle

**`free -g` inside the cgroup is NOT a valid proof** and the brief asked for it: `/proc/meminfo` is
not namespaced without lxcfs, so it reported **378 GiB** — a false negative that would have looked
like the cap had failed. Fourth instrument-not-code false signal this campaign.

**Finding, not caveat: geometry matched, but memory was not the binding constraint on either
side.** Peak RSS 20.3 GiB against a 64 GiB ceiling.

## How musl was confirmed

Built PG 18.6 `REL_18_STABLE` (commit `5d63dbd9774dcb28d7c88bfce42505376b201861`) **inside an
Alpine 3.20 container**, with the OSv arms' exact configure line and CFLAGS from
`apps/postgres18-musl/build.sh`. Not a cross-toolchain; not Alpine's packaged postgres (never
installed — the runtime image adds only `libgcc`).

    file: ELF 64-bit LSB pie executable, x86-64, dynamically linked,
          interpreter /lib/ld-musl-x86_64.so.1
    readelf -l: [Requesting program interpreter: /lib/ld-musl-x86_64.so.1]
    ldd: /lib/ld-musl-x86_64.so.1 (0x7fcc2518a000)
         libc.musl-x86_64.so.1 => /lib/ld-musl-x86_64.so.1
    select version() FROM THE DRIVER:
      PostgreSQL 18.6 on x86_64-pc-linux-musl, compiled by gcc (Alpine 13.2.1_git20240309), 64-bit

No overlayfs between PG and the data: `pgdata on /data/pg type zfs` while `/` is `overlay`.

## Storage: one device, deliberately

m5d.metal has **4x 838 GB instance-store NVMe**. Task C used **one** (`nvme0n1`, single vdev) to
match the OSv arms' single virtio-blk disk; a stripe would have given Linux 4x the spindles the
guest had. `nvme1n1` carried the OSv guest pool. Pool properties byte-identical to the OSv seed
boot: `ashift=12 recordsize=8k compression=off atime=off sync=standard logbias=latency
primarycache=all`.

## ARC: the confound that would have invalidated everything

A cgroup `memory.max` charges PostgreSQL; **ZFS ARC is host kernel memory and is not charged to the
cgroup.** Unbounded, Linux would have had up to ~377 GiB of ARC against the guest's 64 GiB total —
5.9x the entire guest, with a 19 GB dataset, i.e. fully cached. Capped at 16 GiB and **proven to
bind under load**:

    zfs_arc_max = 17179869184        c_max = 17179869184
    arcstats size during run = 16803399184 .. 17224108416   (pinned AT the ceiling)

**Residual, stated because it disfavours Linux:** OSv's ARC is capped by patch 0031 at half of
guest RAM = **~32 GiB**, twice Linux's 16 GiB. **Linux ran with half the cache OSv had and was
still 4.9-21.6x faster.** Host-side commitment ~80 GiB vs the guest's 64 GiB.

## GUCs, verified externally from the driver — identical both arms

| GUC | Linux | OSv guest |
|-----|-------|-----------|
| max_wal_size | 65536 MB | 65536 MB |
| min_wal_size | 2048 MB | 2048 MB |
| shared_buffers | 2097152 8kB | 2097152 8kB |
| effective_cache_size | 4194304 8kB | 4194304 8kB |
| max_connections | 400 | 400 |
| checkpoint_timeout | 900 s | 900 s |
| checkpoint_completion_target | 0.9 | 0.9 |
| fsync | on | on |
| synchronous_commit | on | on |
| full_page_writes | on | on |
| autovacuum | on | on |
| io_method | sync | sync |
| log_checkpoints | on | on |
| wal_level | replica | replica |
| wal_sync_method | fdatasync | fdatasync |
| data_directory | /data/pg | /data/pg |

Both read via `pg_settings` from the driver against the running server, not from a file.

Residual: gcc 13.3.1 (Fedora, OSv arm) vs 13.2.1 (Alpine, mine). Same musl triplet, same configure
line and CFLAGS. Far smaller than the glibc/musl and 16-vs-32-vCPU gaps just eliminated; not worth
a rebuild.

---

# TASK B: the wedge backtrace

Reproduced on **HEAD `e8f578a861646517355ab6a3661b825bef7aeca6`** =
`wip/pg-v26-faultfix-repinned` + merge of `wip/fork-clone-scan` + cherry-pick of `da3041f5d`,
`6265b5ce5`, `7aa9c577c`. Gate passed before boot: `grep -c
remap_segments_in_current_address_space core/elf.cc` = **3**.

Detector was a **real PG query** (StartupMessage + `select 1`, 8 s statement_timeout), not a TCP
probe — TCP-accept is exactly what the wedge passes. Fired on 3 consecutive failures (16:14:30,
16:14:48, 16:15:07) and armed the capture automatically. **The guest was left running**; I attached
to the live qemu and it stayed up 35+ minutes. Nothing was `pkill`ed.

Wedge signature at capture: `TCP_ACCEPT=YES` while no query returns, qemu **26.7% of one core**,
device idle, no OOM/abort/panic.

## FINDING 1 (the bug): `dentry_hash_lock` is held across a blocking allocation

The mutex, read from the live guest:

    $1 = {count = 8, depth = 1,
          owner = std::atomic<sched::thread *> = { 0x40032f208040 },
          waitqueue = {pushlist = 0x6005564a6b00, poplist = 0x0},
          handoff = 0, sequence = 92}

The owner resolves to a **live** thread, not a freed one — which rules out a lost wakeup:

    220584 (0x40032f208040) >/usr/bin/postg cpu0 waiting  sched::thread::switch_to() at arch/x64/arch-switch.hh:175

Owner's stack — it is asleep **inside the allocator** while holding the global VFS lock:

    #0  sched::thread::switch_to (this=0x40011a99a040) at arch/x64/arch-switch.hh:175
    #1  0x0000000040b62a88 in memory::malloc_pools ()
    #2  0x00002000001fffd0 in ?? ()
    #3  0x0000000040373d7a in memory::page_pool::l1::alloc_page () at core/mempool.cc:1464
    #4  memory::untracked_alloc_page () at core/mempool.cc:2015
    #5  memory::pool::add_page (this=0x2000001fffa0) at core/mempool.cc:305
    Backtrace stopped: Cannot access memory at address 0xfffffffffffff6c8

And a victim backend, showing the lock and the path that takes it:

    #7  lockfree::mutex::lock (this=0x40bf5940 <dentry_hash_lock>) at core/lfmutex.cc:129
    #8  mutex_lock (m=0x40bf5940 <dentry_hash_lock>) at include/osv/mutex.h:33
    #9  dentry_lookup (mp=0x3000000c81e0, path=0x2000001fb210 "/pg/postmaster.pid") at fs/vfs/vfs_dentry.cc:116
    #10 namei (path=<optimized out>, dpp=0x2000001fd260) at fs/vfs/vfs_lookup.cc:133
    #11 sys_open (path=0x2000001fd2d0 "/data/pg/postmaster.pid", ...) at fs/vfs/vfs_syscalls.cc:169
    #12 open (pathname=<optimized out>, flags=2) at fs/vfs/main.cc:147

**Mechanism.** A PG backend enters `sys_open` -> `namei` -> `dentry_lookup`, takes the **global**
`dentry_hash_lock`, allocates inside the locked region, and `l1::alloc_page` finds the per-CPU L1
pool empty. It then blocks **inside the allocator's own refill path** (`l1::alloc_page` is
`while (!(ret = alloc_page_local())) { refill(); }`, and `l2::alloc_page_batch` at
`core/mempool.cc:1484` loops calling `refill()` itself) — **still holding the lock**. The
`page_pool_l2` thread parked at `core/mempool.cc:1763` is a *symptom*, not the blocking dependency:
the consumer does its own refill.

This is why inspection misses it: `dentry_lookup` and `drele` both unlock before returning and
contain no *named* blocking call. The sleeping site is the allocator, reachable from **any**
allocation. The pattern to grep for is "holds a lock across a malloc", not "holds a lock across a
blocking call".

**System state at wedge — everything stops rather than slowing:**

    1,172 OSv threads: 1,138 waiting, 32 running -- and all 32 "running" ARE the idle threads.
    All 32 vCPUs [halted] in sched::cpu::do_idle at core/sched.cc:610 (inside
      handle_incoming_wakeups() with an empty mask). ZERO runnable work.

    Blocked-thread histogram:
      735  bsd/porting/synch.cc:102     synch_port::_msleep  (ZFS/BSD; incl. 64 z_unlinked_drain,
                                        64 dp_zil_clean_taskq, every z_wr_iss/z_wr_int/z_rd_iss)
      184  arch/x64/arch-switch.hh:175  >/usr/bin/postgres backends (behind the mutex)
       32  rcu.cc:185 / percpu-worker.cc:92 / mempool.cc:1648 / async.cc:190  (normal housekeeping)
       22  core/condvar.cc:62
        2  drivers/virtio-blk.cc:389    BOTH virtio-blk completion threads idle in req_done()

**This explains the previously "unattributed" signature exactly:** device 0.00% util because both
virtio-blk completion threads sit idle in `req_done()` with nothing outstanding; qemu ~26-50% of one
core because 32 vCPUs spin in the idle loop; zero page faults because nothing executes. Not
CPU-bound, not IO-bound — a lock held across a sleeping allocation.

**It is not memory exhaustion**, which decides that fixing the lock is sufficient:

    memory::global_l2._nr = 0            L2 page-batch stack EMPTY
    Free Memory: 28,920,045,568 (42.08%) 26.9 GiB genuinely FREE
    Total: 68,718,926,848   Mmap: 18,217,312,256 (26.51%)

27 GiB free while the batch stack is empty: the refill path was stuck, not starved. Removing the
allocation-under-lock removes the deadlock without leaving an OOM stall underneath.

**Limit, stated rather than guessed:** I could not name the exact `malloc` call site under the lock.
Frame #2 is `0x00002000001fffd0 in ?? ()` and the unwind dies at `Cannot access memory at address
0xfffffffffffff6c8` because the allocation runs on a lazily-mapped stack region. Candidates *by
inspection only, unconfirmed*: `dentry_alloc`'s `new dentry` / `strdup(d_path)` at
`fs/vfs/vfs_dentry.cc:105-107`. A maintainer can settle it by reading those paths far more cheaply
than from a truncated unwind.

## FINDING 2 (independent, scalability): the lock is global across 32 buckets that already exist

`fs/vfs/vfs_dentry.cc:50` declares one `static mutex dentry_hash_lock` guarding
`dentry_hash_table[DENTRY_BUCKETS]` — **32 buckets, no per-bucket locking**, taken at 14 sites. Every
path lookup in the system serialises on one mutex; 184 PG backends were parked behind it. This is a
defect whether or not it causes the hang, the buckets already exist, so per-bucket locking is a
small change, and it is a plausible contributor to the 4.9x -> 21.6x widening with concurrency.

## Non-recurrences (results in their own right)

- **No OOM / mempool abort.** The "37.41 GiB free, largest contiguous range 1.00 MiB" failure did
  **not** reproduce. `866bc8b6a` (retry-reclaim) and `859210d54` (largest-free-range reporting) are
  already in this base. Second independent non-recurrence.
- **No elf/dlopen page fault** on the fixed base (grep=3).

An earlier boot on the **unfixed** base (`124caf42a`, `grep=0`) did reproduce the pre-fix signature
verbatim — `RIP: elf::object::dynamic_tag+12` via `dlsym+268 -> lookup_symbol_deep+29`. That is
expected pre-fix behaviour, **not** evidence the fix is incomplete: `remap_segments_in_current_
address_space` count is 0 on `wip/pg-v26-faultfix-repinned` and 3 on the fix branches. **"repinned"
does not contain the elf fix**; the two must be stated together.

## Not captured

The `z_wr_iss`/`txg_sync` stack and the run-queue/wakeup-mask dump. The qemu gdb stub stopped
answering after ~8 successive attaches (`Remote replied unexpectedly to 'vMustReplyEmpty': timeout`)
while the guest itself stayed up. So the ZFS-pipeline-vs-virtio-blk completion pairing is unresolved
beyond the histogram above.

---

## TASK A (Firecracker): NOT REACHED

Not started. C consumed the budget and B was the higher-value artifact. Correct trade per the
standing priority; said plainly rather than rushed. If picked up: base
`wip/pg-v26-faultfix-repinned` + `fork-clone-scan` is a genuine 2-commit / +211-line delta confined
to `core/mmu.cc`, so a Firecracker number on it is legitimately comparable to the earlier x86
QEMU-KVM figures.

## Substrate bugs worth banking

1. **`usr.img` is qcow2, not raw.** Passing `format=raw` makes OSv read the qcow2 header and fail
   `spa_import_rootpool` with "Cannot find the pool label".
2. **`--rootfs=zfs`** is the correct cmdline for a ZFS-root image, not
   `--mount-fs=zfs,/dev/vblk0.1,/`.
3. The guest hangs silently after `ZFS: root mounted ok` with **no `eth0:` line** if
   `--ip`/`--defaultgw` are omitted (DHCP block, as briefed).
4. **GUCs must be on the `postgres` cmdline.** The baked seed cluster carries stock defaults
   (`shared_buffers=128MB`, `max_connections=100`, `max_wal_size` 1GB). My first Task B guest ran
   with no `-c` args and produced a checkpoint storm (540 MB distance, "4 seconds apart", one
   269.744 s checkpoint write) that I briefly mis-reported as an OSv pathology. **Retracted**: it
   was my missing GUCs. The prior x86 arm's config was correct and its numbers stand.
5. **`module: build` shadow trap reproduced exactly as briefed**: `BUILD_RC=0`, all 5 OpenZFS libs
   present, and **0 postgres entries** in `usr.manifest` (usr.img 10.9 MB, 22 manifest lines).
   `make -n build` prints `'build' is up to date` while `install/` does not exist. Workaround: call
   `./build.sh` directly. Verify by size: **65 MB** with postgres vs **10.9 MB** without.
6. **fedora:39 needs `perl-FindBin`** or `genbki.pl` fails with "Can't locate FindBin.pm".
7. gdb needs `set auto-load safe-path /` **and** `file loader.elf` before `source scripts/loader.py`,
   or the `osv` macros never register (`Undefined command: "osv"`).
8. OpenZFS proof is build-time only (no version banner exists): **302** `open_zfs` objects vs **0**
   `bsd/*/fs/zfs` objects, plus `libsolaris/libzfs_core/libzutil/libshare/libtpool`.

## Premises corrected

`free` inside a cgroup (not namespaced, reports the host); "32 physical cores on one socket"
(impossible on m5d.metal); the ARC hole (host kernel memory, uncharged to the cgroup — would have
given Linux 5.9x the guest's total RAM as cache); "fork-clone-scan is 8 commits" (2 against this
base — scope is a property of the (base, branch) pair); "repinned contains the elf fix" (grep=0);
"64GB makes num_timed dominate" (1 timed / 18 requested at 614k NOPM); "no scaling region on Linux
either" (16-vCPU artifact); and my own checkpoint-storm claim, retracted within a message of making
it.
