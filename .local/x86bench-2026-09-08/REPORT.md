# x86_64: ELF cross-address-space dlopen fix validation + PostgreSQL 18.6 benchmark

Boxes: `i-00afcd7e704f2feaf` (m5d.metal, OSv host) and `i-0d8c434d77879b1f9`
(c5.4xlarge Ubuntu 24.04, driver). Both terminated, 0 orphans.

---

## 1. TASK A VERDICT: PASS on x86_64

The fix branch builds cleanly for x86_64 on the repinned base (no conflicts, no
papering over). All three new symbols are in the kernel:

    00000000402c8b60 T elf::object::mapped_in_current_address_space()
    00000000402c9ab0 T elf::object::run_init_funcs_for_new_address_space()
    00000000402cd090 T elf::object::remap_segments_in_current_address_space()

Committed test found (not guessed): `6265b5ce5` added
**`tests/tst-fork-dlopen-as.cc`** + `tests/libdlopenas.cc` (not
`tst-fork-xas-dlopen.cc`, which is the earlier x86 *reproducer* in
`.local/xas-dlopen-x86/`). Same image, same qemu 8.1.3 `-M pc`, 4 vCPU / 4 GB,
`conf_fork=1 fs=rofs image=tests`. Only difference between the two runs is
`git revert` of the elf commit.

### PRE-FIX (fix reverted, `nm | grep -c mapped_in_current_address_space` = 0)

    tst-fork-dlopen-as: dlopen from an address space that did not load
    PASS: round 0: child dlopen + dlsym + call (status 0)
    page fault outside application, addr: 0x000010000002d000
    [registers]
    RIP: 0x00000000402c923c <elf::object::dynamic_tag(unsigned int)+12>
    RAX: 0x000010000002ddd8  RBX: 0x000010000000211e  RCX: 0x0000000000000006
    ...
    [backtrace]
    0x000000004031069b <page_fault+139>
    0x000000004030f3d2 <???+1076949970>
    0x00000000402d300d <elf::object::lookup_symbol_deep(char const*)+29>
    0x00000000403eb54c <dlsym+268>
    0x00001000000012b7 <???+4791>

Round 0 (the AS that loaded it) passes; the very first cross-AS cache hit faults.
`page fault outside application` + `elf::object::dynamic_tag` via `dlsym ->
lookup_symbol_deep`, exactly the production signature. `RAX` = fault page +
0xdd8 = the `_dynamic_table` walk cursor.

### POST-FIX (same tree, fix restored)

    tst-fork-dlopen-as: dlopen from an address space that did not load
    PASS: round 0: child dlopen + dlsym + call (status 0)
    PASS: round 1: child dlopen + dlsym + call (status 0)
    ... (rounds 2..10) ...
    PASS: round 11: child dlopen + dlsym + call (status 0)
    PASS: parent (the address space that did not load it) dlopen + dlsym + call
    tst-fork-dlopen-as: 0 failures

**AS0-as-second-consumer is exercised and passes** — that is the final `PASS`
line: the first loader is a forked child, and the second consumer is the parent
(AS0) address space. A fork-child-only fix would fail exactly there. Rounds
0..11 plus the AS0 case, 0 failures.

The test also defends against the weaker failure mode: `dlopenas_value()` returns
a constructor-initialised global (41+1), so a remap that mapped segments but
skipped relocations or constructors would return 0 or fault rather than 42.

**I did not probe VMA presence with `msync()`.** The reference x86 reproducer's
`mincore()` instrument was reused as-is; no new prober was written.

---

## 2. Result identity

| field | value |
|---|---|
| osv SHA | `03d7931db2ff6c3c953503ab8f5fe067799efef9` |
| base branch | `gh-fork/wip/pg-v26-faultfix-repinned` (`124caf42a`) |
| fix applied as | `git cherry-pick da3041f5d 6265b5ce5` (clean, no conflicts) |
| **apps SHA** | **`b38b99cd9302af01fb388e569bc0911c0e90bbc4`** |
| apps resolution | `git submodule update --init apps` -> RC=0, **no manual substitution** |
| openzfs submodule | `zfs-2.4.2` (`META`: Version 2.4.2) |
| PG branch / version | `REL_18_STABLE` / **18.6** (`x86_64-pc-linux-musl`, gcc 13.3.1) |
| configure line | `--prefix=... --without-icu --without-zlib --without-readline --without-libxml --without-lz4 --without-zstd CFLAGS="-O2 -g -fPIC -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -DWAIT_USE_SELF_PIPE -idirafter /usr/include"` |
| build | `conf_fork=1 conf_zfs=openzfs fs=zfs image=zfs,zfs-tools,postgres18-musl` |
| host | m5d.metal, 96 vCPU, 377 GiB, AL2023; guest 32 vCPU / 64 GiB |
| hypervisor | qemu **8.1.3** in fedora:39 container, `-M pc`, `-kernel loader.elf` |

**I used your repinned branch, not a manual substitution.** Both routes give the
same `apps` SHA; yours is the rebuildable one. `126caf42a`'s only content is the
apps re-pin, so the benchmark tree is `73a332f26` + apps-repin + the 2 fix commits.

### Substrate proofs

ZFS properties, all `SOURCE=local`, read from the guest at pool create:

    pgdata  ashift        12        local
    pgdata  recordsize    8K        local
    pgdata  compression   off       local
    pgdata  atime         off       local
    pgdata  sync          standard  local
    pgdata  logbias       latency   local
    pgdata  primarycache  all       local

GUCs, read **externally** from the driver via `pg_settings`:

    autovacuum                   on
    autovacuum_naptime           15 s
    checkpoint_completion_target 0.9
    checkpoint_timeout           900 s
    data_directory               /data/pg
    effective_cache_size         4194304 8kB   (= 32 GB)
    fsync                        on
    io_method                    sync
    log_checkpoints              on
    max_connections              400
    max_wal_size                 65536 MB      (= 64 GB, not 16)
    min_wal_size                 2048 MB
    shared_buffers               2097152 8kB   (= 16 GB)
    synchronous_commit           on

**PGDATA is not ramfs.** Full chain, each link measured:

    SHOW data_directory            -> /data/pg
    pg_relation_filepath(customer) -> base/24587/24588
    resolved                       -> /data/pg/base/24587/24588
    /data/pg = ZFS dataset pgdata -> /dev/vblk1 -> /mnt/nv/pool.raw -> /dev/nvme0n1
    df -h /mnt/nv                  -> /dev/nvme0n1  838G  ... /mnt/nv
    mount                          -> /dev/nvme0n1 on /mnt/nv type xfs
    lsblk                          -> nvme0n1 838.2G "Amazon EC2 NVMe Instance Storage"
    tmpfs mounts under /mnt/nv or /work: 0

`pool.raw` grew **54 M -> 71 G -> 195 G** as the schema loaded. A tmpfs cannot
grow a file on an NVMe device. The module default
(`--mount-fs=ramfs,/dev/null,/data`) was overridden; `module.py` now imports the
pool and mounts it at `/data`.

**OpenZFS, not legacy bsd_zfs**, three ways: 302 `modules/open_zfs` objects vs
**0** `bsd/.../fs/zfs` objects; `libsolaris.so` + `libzfs_core/libzutil/libshare/
libtpool` in the manifest; runtime banner. `open_zfs` was NOT passed explicitly.

**Banner correction.** The brief says the guest prints `zfs-2.4.1-osv`. It prints:

    ZFS: OpenZFS 5000 initialized
    [ZFS] Pool 'pgdata' is up-to-date at version 5000

Source is `printf("ZFS: OpenZFS " SPA_VERSION_STRING " initialized\n")` in
`module/os/osv/zfs/zfs_initialize_osv.c:346` — `SPA_VERSION_STRING` is the pool
format (5000), never a package version. There is no `zfs-2.4.1-osv` string in the
tree; the submodule is `zfs-2.4.2`. **Use "OpenZFS 5000 initialized" + the
submodule tag as the OpenZFS proof, not a version banner.**

**External load generation proven before any load run:**

    select 1, inet_server_addr(), inet_client_addr(), version()
    1|192.168.100.2|172.31.10.230|PostgreSQL 18.6 on x86_64-pc-linux-musl...

Driver -> guest, over tap0/br0 with a DNAT on the metal private IP. Not an
on-host driver. (qemu had to run in the **host** netns; in the container's netns
its tap0 was a private interface with NO-CARRIER and the guest was unreachable.)

---

## 3. NOPM / TPM: QEMU-KVM, VU x 3 repeats

200 warehouses, 19 GB database (> 16 GB shared_buffers), rampup 2 / duration 5,
`pg_timeprofile true`, xtprof rotated per run.

| VU | r1 | r2 | r3 | **median** | min-max | spread | TPM (median) |
|---|---|---|---|---|---|---|---|
| 8 | 42864 | 43407 | 45463 | **43407** | 42864-45463 | 5.9% | 100209 |
| 16 | 37503 | 39896 | 37690 | **37690** | 37503-39896 | 6.3% | 86788 |
| 32 | 34977 | 34789 | 34686 | **34789** | 34686-34977 | **0.8%** | 80250 |
| 64 | 26874 | *62910* | 28377 | **28377** | 26874-62910 | **134% FLAGGED** | 65360 |
| 96 | 26047 | 25125 | 26103 | **26047** | 25125-26103 | 3.9% | 60166 |

All 15 cells had **0 HammerDB vuser failures**. Peak throughput is **VU8**, then
monotonic decline — no scaling region, the same shape as the Linux reference.

**The VU64 spread is an artifact of a boot boundary, not variance.** `r2`
(62,910) is the first run after a fresh boot + crash recovery, with a cold-then-
warming ARC; its connect-probe tail is simultaneously the worst in the whole
campaign (p99 5.45 s, max 10.07 s, 73 samples >= 1 s vs 1 and 4 for r1/r3). A
later VU96 run in the same post-recovery position reproduced the pattern exactly
(63,593 NOPM, p99 5.72 s). So "high NOPM + destroyed tail immediately after
recovery" is systematic. Excluding r2, VU64 is 26874/28377, spread 5.6%. I am
reporting the flagged number, not quietly dropping it.

Per-vCPU normalised, against the Linux reference (99,504 NOPM @ VU8 on 16 vCPU):

| | peak NOPM | vCPU | NOPM/vCPU |
|---|---|---|---|
| Linux/PG18.6 | 99,504 | 16 | 6,219 |
| OSv x86 (this) | 43,407 | 32 | 1,357 |

OSv reaches **~22% of Linux per vCPU**. Residual confounds, stated: 16 vs 32 vCPU
geometry (and both peak at VU8, so neither was scaling), musl vs glibc, and
Linux-on-VM vs OSv-on-metal-under-KVM.

---

## 4. Checkpoints at `max_wal_size=64GB`: your premise confirmed

**Timed checkpoints now dominate completely.** Over the long healthy run:

    checkpoint starting: time -> 6
    checkpoint starting: wal  -> 0
    checkpoint starting: end  -> 1  (end-of-recovery)

vs the Linux 16 GB run's `num_timed=0` with 49 of 51 WAL-triggered every ~72 s.
`pg_stat_checkpointer` mid-run read `num_timed=1, num_requested=1`; the log is the
better instrument here because the counter resets with the postmaster.

Checkpoints now land on a **15-minute cadence** (19:50:51, 20:05:51, 20:20:51,
20:35:51, 20:50:51, 21:05:51 — exactly `checkpoint_timeout` apart) instead of at
arbitrary phase, which is precisely the structural fix you predicted.

**And spread dropped below 15%: 0.8%-6.3% on every cell with a stable guest**
(VU8 5.9%, VU16 6.3%, VU32 0.8%, VU96 3.9%), vs 30-35% at 16 GB. Worth noting
against the aarch64 arm, which made the same change and still shows 27.6%/29.7%:
**the knob is necessary and, on x86, sufficient** — so whatever drives the
aarch64 variance is ISA- or arm-specific, not the checkpoint schedule.

---

## 5. NEWORD p50/p95/p99 per VU (rotated xtprof logs)

CALLS-weighted across vusers; per-vuser p99 range shown because per-vuser
percentiles cannot be averaged into a true global percentile.

| VU | NEWORD calls | p50 | p95 | p99 | p99 range across vusers |
|---|---|---|---|---|---|
| 8 (r1/r2/r3) | 304k/304k/321k | 5.8 / 5.7 / 5.6 ms | 12.9 / 12.7 / 9.8 ms | 22.0 / 22.1 / 18.9 ms | 18.2-23.1 |
| 16 | 262k/284k/262k | 15.0 / 13.7 / 15.0 ms | 22.8 / 21.2 / 23.4 ms | 32.6 / 33.3 / 33.4 ms | 31.7-35.9 |
| 32 | 250k/245k/243k | 31.6 / 32.8 / 32.4 ms | 47.0 / 47.1 / 48.1 ms | 61.1 / 57.3 / 62.2 ms | 55.0-69.4 |
| 64 | 470k(r2)/151k(r3) | 22.2 / 82.4 ms | 67.5 / 244.0 ms | 147.5 / 322.2 ms | 55.1-516.2 |
| 96 | 188k/180k/107k | 126.6 / 129.0 / 204.9 ms | 174.6 / 191.9 / 349.4 ms | 219.1 / 253.6 / 530.1 ms | 190.8-673.9 |

Rotation caveat, and a **methodology bug you should know about**: rotating at run
*start* is not sufficient. HammerDB flushed a straggler report from the previous
run into `kvm-vu64-r3`'s file, which then reported **160 vusers for a 64-vu run**
and mixed two runs' percentiles. Detect it by counting `Time Profile Report`
headers per file and parsing only the last block. The table above is corrected;
VU64-r1's log was lost entirely to the same effect.

---

## 6. Connect-probe distribution, with NOPM alongside

Fresh connection + `select 1` + close, 1/s, **timed window only**, from the driver.

| VU | rep | n | median | p95 | p99 | max | >=1s | >=5s | >=10s | NOPM |
|---|---|---|---|---|---|---|---|---|---|---|
| 8 | r1 | 300 | 0.334 s | 0.380 | 0.508 | 0.594 | 0 | 0 | 0 | 42864 |
| 8 | r2 | 300 | 0.342 | 0.397 | 0.601 | 0.647 | 0 | 0 | 0 | 43407 |
| 8 | r3 | 300 | 0.341 | 0.404 | 0.587 | 0.671 | 0 | 0 | 0 | 45463 |
| 16 | r1 | 300 | 0.368 | 0.433 | 0.636 | 0.685 | 0 | 0 | 0 | 37503 |
| 16 | r2 | 300 | 0.365 | 0.426 | 0.562 | 0.593 | 0 | 0 | 0 | 39896 |
| 16 | r3 | 300 | 0.370 | 0.435 | 0.643 | 0.677 | 0 | 0 | 0 | 37690 |
| 32 | r1 | 300 | 0.401 | 0.514 | 0.710 | 0.876 | 0 | 0 | 0 | 34977 |
| 32 | r2 | 300 | 0.398 | 0.474 | 0.601 | 0.687 | 0 | 0 | 0 | 34789 |
| 32 | r3 | 300 | 0.412 | 0.507 | 0.717 | 0.745 | 0 | 0 | 0 | 34686 |
| 64 | r1 | 300 | 0.492 | 0.635 | 0.813 | 1.187 | 1 | 0 | 0 | 26874 |
| 64 | r2 | 220 | 0.669 | 2.871 | 5.446 | 10.069 | 73 | 4 | 1 | 62910 |
| 64 | r3 | 299 | 0.499 | 0.685 | 1.122 | 1.533 | 4 | 0 | 0 | 28377 |
| 96 | r1 | 300 | 0.605 | 0.741 | 0.838 | 1.089 | 2 | 0 | 0 | 26047 |
| 96 | r2 | 298 | 0.628 | 0.771 | 1.145 | 2.085 | 5 | 0 | 0 | 25125 |
| 96 | r3 | 258 | 0.694 | 1.890 | 4.049 | 8.554 | 39 | 3 | 0 | 26103 |

Zero probe errors in every cell. Against the references:

| | median | worst | >= 1 s |
|---|---|---|---|
| Linux/PG18.6 (4350 samples) | 4.0-4.3 ms | 17.6 ms | 0 |
| OSv aarch64 (prior) | 262 ms | 501 ms | 0 |
| **OSv x86 VU8 (this)** | **334 ms** | **594 ms** | **0** |
| OSv x86 VU32 | 401 ms | 876 ms | 0 |
| OSv x86 VU96 | 605 ms | 1089 ms | 2 |

**The headline latency gap is confirmed and quantified: ~80x on the median**
(334 ms vs 4.2 ms) for what is nothing but connect + trivial query + close. It
degrades gracefully with VU (334 -> 401 -> 605 ms) rather than collapsing, and
**the VU32 gate you flagged as untested now passes: 0 samples >= 1 s.** The x86
median is in the same regime as aarch64's 262 ms, so this cost is
ISA-independent — consistent with per-connection fork being the dominant term.

---

## 7. Bottleneck at VU32 and VU96 — the decision-relevant answer

### VU32: an unattributed stall. Neither the device nor the WAL lock.

`pg_stat_activity`, 10 samples, 6 s apart, during the timed window:

    (running)|(cpu)       25-32 of 32
    LWLock|WALWrite       1-5
    IO|WalSync            0-2
    Client|ClientRead     1-2
    Lock|transactionid    0-1

Host `iostat -x /dev/nvme0n1` in the same window (parsed by header name):

    MEDIAN %util   = 15.70   (min 4.47  max 21.60, n=12)
    MEDIAN w_await = 0.18 ms (min 0.16  max 0.26)
    MEDIAN aqu-sz  = 0.42    (min 0.22  max 0.60)
    MEDIAN wkB/s   = 119868  (min 38784 max 158176)

Host-side guest CPU, measured from `/proc/<qemu>/stat` utime+stime deltas:

    qemu total CPU = 40-50% of ONE core, against a 3200% ceiling (32 vCPU)
    host overall: 99.8% idle

**So: the device is not the limit (16% util, 0.18 ms writes, queue depth 0.4),
`LWLock:WALWrite` is not the queue (1-5 of 32), and the guest is burning ~1.6% of
its available CPU. The work is neither on the device nor on a CPU.** I call this
an **unattributed stall**: OSv-side blocking that surfaces through no PostgreSQL
wait event.

The inference worth naming, because I got it wrong first and it is the trap:
**PostgreSQL `state='active'` means "not waiting on a REGISTERED wait event", not
"on CPU".** A backend blocked in something OSv does not expose as a wait event is
indistinguishable from one doing arithmetic. My interim "CPU-bound" claim was
refuted by the host counter by ~60x. Any conclusion from `pg_stat_activity` alone
needs a host-side CPU counter next to it.

This is *consistent with* but *not the same as* the aarch64 arm's idle-device
finding: there the backends were queued on `WALWrite`; here they are not.

### VU96: the WAL lock does become the queue — with the device still idle

    (running)|(cpu)      45-52 of 96      LWLock|WALWrite    32-85 of 96
    Lock|transactionid   9-10             LWLock|LockManager 2-5

    MEDIAN %util   = 7.20    (min 4.74 max 10.60)
    MEDIAN w_await = 0.24 ms
    MEDIAN aqu-sz  = 0.23
    qemu CPU       = 420-530% of 3200 (~4-5 of 32 vCPU)

**Answer to your question, per VU level:** at VU96 OSv shows
`LWLock:WALWrite` on 32-85 of 96 backends **with the device 93% IDLE** (7.2%
util, 0.24 ms writes) — the OSv-side-cost signature, matching aarch64
qualitatively. But at VU32 OSv shows **neither** pattern. So the three-way split
holds, with a refinement: the OSv WALWrite-with-idle-device signature is a
**high-concurrency** phenomenon, and at moderate concurrency the limiter is the
unattributed stall instead. Notably the device is *less* busy at VU96 than VU32
(7.2% vs 15.7%) while throughput is *lower* — the guest is doing less I/O work
per unit time as load rises, which is a software serialisation signature, not
saturation.

### The prior "ZFS COW wall at ~60 MiB/s" does not reproduce

That figure came from three checkpoints labelled post-recovery / mid-load /
pre-crash in a run that **never reached a timed window** (it crashed during
rampup 5x). It measured WAL replay and rampup. In steady state this run sustains
**~120 MB/s of writes at 16% device utilisation with 0.18 ms latency** and
`sync=0.03-0.07 s` on every checkpoint. ZFS COW write amplification is not the
limiter here. Treat the old number as an artifact of the crash, not a finding.

---

## 8. Crashes and hangs — two distinct guest-kernel failures, neither is the elf bug

**Both are reported as results. Neither is the fault Task A fixed: `page fault
outside application` count is ZERO across every benchmark boot** (68,751-line
console for the first, and 0 in each subsequent boot). The fix's own gate held
for the entire campaign, through ~1.3 M NEWORD transactions and thousands of
backend forks each dlopening from a fresh address space.

### 8a. Silent hang with a stuck checkpoint (VU64 window, 21:05:51 UTC)

Last console line, then nothing ever again:

    2026-09-08 21:05:51.340 UTC [2342] LOG:  checkpoint starting: time

State while wedged:

    TCP :5432                 still ACCEPTS connections
    any query                 never returns (psql times out at 25-30 s)
    device %util              0.00  (completely idle)
    qemu CPU                  50% of one core
    page faults               0
    OOM / abort / assert / panic in 68,751 lines   none

A prior checkpoint had completed normally 1 minute earlier, so the checkpointer
died between two timed checkpoints. Given the VU32 finding, the most economical
reading is the unattributed stall becoming permanent, but I have no backtrace to
prove it — see the honest miss below.

### 8b. Guest OOM abort — allocator fragmentation, not memory exhaustion

A later VU64 run aborted with interleaved register dumps from all 32 vCPUs. The
signature, recovered from the byte-interleaved console:

    OOM total_free_Kb=0000000002569140
    OOM largest_free_range_Kb=00000000000003fc
    Out of memory: could not reclaim any further. Current memory: 39227712 Kb
    [backtrace]

Decoded against `core/mempool.cc:1007` (`debug_early_u64(..., total_free >> 10)`,
printed hex):

    total_free           = 0x2569140 Kb = 37.41 GiB free
    largest_free_range   = 0x3fc     Kb =  1.00 MiB

**37.4 GiB free, but the largest contiguous run is 1 MiB.** That is a
fragmentation wall in the page-range allocator, not memory exhaustion — the
allocation that failed simply needed more than 1 MiB contiguous. This is what
the `mm: report largest free range on OOM` commits on this branch were added to
diagnose, and they worked. Both failures are high-VU (64+); VU8-VU32 ran for
hours without either.

Neither failure is attributable to the elf fix, and the fix is required for any
of this to run at all.

---

## 9. Deviations and honest misses

**Not done: Firecracker — NOT REACHED.** QEMU-KVM took the full budget
(~5.5 h wall). Per your priority, the primary arm is complete (all 5 VU levels,
3 repeats, probe + xtprof + bottleneck instruments) rather than two rushed
halves. Firecracker's open question here is throughput parity; the earlier
campaign already established it is not exempt from guest-kernel bugs.

**My worst miss: I killed the wedged guest before taking a backtrace.** You
asked for `thread apply all bt`, and it was the single highest-value artifact
available. I ran `pkill qemu` to free the qcow2 lock and destroyed the state. I
then armed a watcher (`/work/wedgewatch.py`) that detects a wedge via a real
PG StartupMessage — TCP-accept alone is not a liveness test, since that is
exactly what the wedge passes — and auto-captures both host-side and guest-side
(`-gdb tcp::1234`, `osv info threads`) backtraces. It never fired again: the
second failure was the OOM abort, not a hang. **The hang backtrace is still
owed and needs a rerun.**

**Other deviations, all mechanical:**
- `scripts/build` on this branch is bash, not Python; needs `python3-setuptools`
  (Python 3.12 dropped `distutils`) and `perl-FindBin` in fedora:39, else PG's
  `genbki.pl` fails.
- `apps/postgres18-musl/Makefile` has `module: build` with a real `build/`
  directory, so make silently skipped `build.sh` and produced a
  **PostgreSQL-free image while reporting success**. Fixed with `.PHONY: module
  build`. `scripts/build` also exits 0 when a module's make fails, so RC is not
  a build-success signal — check for artifacts.
- `run.py` hardcodes `-machine q35` on x86 (it reboot-loops); the qemu line was
  built by hand with `-M pc`. Images are **qcow2** — passing `format=raw` makes
  the partition table unreadable and rofs/zfs mount fails.
- qemu must run in the **host** network namespace for tap0 to reach the bridge.
- `module.py` uses `api.run("...")`; there is no `api.get_env`.
- initdb ran on the host and was baked read-only + `seed_copy`'d, since OSv stubs
  `popen()`. No cpiod, no ramfs.
- Pool created **once** in a dedicated seed boot; every benchmark boot was
  import-only (`/zpool.so import -f -N pgdata ; /zfs.so mount pgdata`). Verified
  persistent: `count(*) from warehouse` = 200 after every reboot, including after
  both crashes.

**Reusable methodology note (`runtimer` -> `vucomplete`), as requested.**
HammerDB 6.0 deprecated `runtimer`: it prints "runtimer command has been
deprecated and is not required for version v6.0" and returns immediately, so
`vudestroy` fires while vusers are still running. The run then ends with
"Virtual Users remain running in background or shutting down, retry" and **no
`TEST RESULT` line** — a lost data point that reads like a platform failure. Fix:

    vurun
    for {set i 0} {$i < 1200} {incr i} { if {[vucomplete]} break ; after 1000 }
    vudestroy

After this, cells end with `ALL VIRTUAL USERS COMPLETE` / `vudestroy success`.
**Correction to my own earlier attribution:** I first blamed this harness bug for
the lost VU64-r2/r3 and VU96 cells, but those ran *after* the 21:05:51 wedge, so
the wedge is the likelier cause. The `runtimer` defect is real and independently
worth fixing; it was not what killed those specific cells.

Also: rotate xtprof per run **and** parse only the last report block (see §5),
and never use `msync()` to test whether a VMA exists — `file_vma::sync()` returns
ENOMEM for any non-`MAP_SHARED` mapping. `mincore()` is the correct instrument.

**Boxes terminated: `i-00afcd7e704f2feaf`, `i-0d8c434d77879b1f9`. Orphan count 0**
(filtered on `Owner=agent-x86bench`; other projects' instances untouched).
Raw logs: `.local/x86bench-2026-09-08/{x86bench-runs.tgz,x86bench-host.tgz}`.
