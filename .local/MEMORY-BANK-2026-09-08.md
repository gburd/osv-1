# OSv project: durable lessons (banked 2026-09-08)

> **CORRECTION 2026-09-09: "no scaling region on Linux either" was a 16-vCPU SATURATION ARTIFACT.**
> On matched geometry (32 logical CPUs, bare metal, musl) Linux scales strongly:
>
>       VU8 232,139 | VU16 397,160 | VU32 527,415 | VU64 627,652 (PEAK) | VU96 581,061
>
> Peak at **VU64, 2.7x its own VU8 figure**. The old 16-vCPU VM reference peaked at VU8 and declined
> monotonically, and I generalised that shape into "PostgreSQL/TPROC-C has no scaling region on this
> workload, on any platform." **That was wrong.** The platforms differ in SHAPE, not only level:
> Linux converts added concurrency into throughput up to VU64; OSv converts it into queueing
> immediately (peaks at VU8 and declines). The gap therefore WIDENS with concurrency:
> 5.3x at VU8, 10.5x at VU16, 15.2x at VU32, 22.1x at VU64, 22.3x at VU96.



> **CORRECTION 2026-09-08: the `zfs-2.4.1-osv` banner does NOT exist.** I propagated this as a
> runtime verification step and it is wrong. `grep -rl "zfs-2.4.1-osv"` across all C/C++ sources
> returns **nothing**. What the guest actually prints is `ZFS: OpenZFS 5000 initialized`, where
> `5000` is `SPA_VERSION_STRING` (`bsd/sys/cddl/.../sys/fs/zfs.h:367`) - the **pool format
> version**, identical for bsd_zfs and OpenZFS, and never a package version. So that line proves
> nothing about which implementation is loaded.
>
> **The reliable proofs that OpenZFS (not legacy bsd_zfs) is in the image are build-time:**
> (a) `modules/open_zfs/openzfs` objects compiled (282 in one measured build) versus **0**
> `bsd/.../fs/zfs/spa.c` objects; and (b) the four OpenZFS-only userspace libs shipped
> (`libzfs_core`, `libzutil`, `libshare`, `libtpool`), which `modules/zfs-tools/module.py` adds
> **only** under `conf_zfs=openzfs`. The vendored submodule is `6330a45b0` (META 2.4.2), not 2.4.1.



Written to a file because the `memelord` MCP server is crashing on connect
(`Connection closed (GenericFailure)`), so `memelord_memory_report` could not persist these.
**Re-file these into memelord when it is healthy again.** Each entry below is tagged with the
memelord `type` it should be filed under.

---

## [insight] Root cause: fork + dlopen cross-address-space cache hit

`elf::program`'s object cache (`_files`) is **process-GLOBAL**, but PT_LOAD segment mappings are
**PER-address-space** (`file::load_segment` -> `mmu::map_file` -> `cur_vma_list()`).
`program_base = 0x100000000000` is app **PML4 slot 32**, and `core/mmu.cc:156` clones only slots
1..127 per child. So a cache hit at `core/elf.cc:~1626` returns an object whose
`_base`/`_dynamic_table` point at VAs mapped in **no** address space. The cache-hit path contains
**zero** references to any address space.

Symptom: page-aligned `page fault outside application` inside `elf::object::dynamic_tag` via
`dlsym` -> `lookup_symbol_deep`, at a **byte-identical address every time** because the address is
frozen at first load (every later consumer is a cache hit).

Confirmed on **both x86_64 and aarch64** with a 60-line fork+dlopen C reproducer: no PostgreSQL,
no ZFS, no HammerDB, faults in under a second. Fixed on `gh-fork` branch
`fix/elf-object-cache-address-space` (`da3041f5d`, `6265b5ce5`) via
`object::mapped_in_current_address_space()` + `remap_segments_in_current_address_space()` +
`run_init_funcs_for_new_address_space()`. Filed on **PR #1456**, not master, because
`upstream/master` has zero `CONF_fork`/`clone_address_space` references.

Two implementation traps, each cost a build: re-mapped **writable** segments come back
**unrelocated** (a *successful* `dlsym` then faults at address 0 on a NULL GOT entry), so the remap
must re-run `relocate`/`fix_permissions`/constructors; and the fork-shared range registration must
be **one-shot** or `chunk_magic` aborts on the caller's fork arena.

## [correction] Page-aligned fault addresses prove nothing

`page fault outside application` with a **page-aligned** address means the **VMA lookup FAILED**
(no VMA covers it), not a page-granular event. `core/mmu.cc:2457` does
`align_down(addr, page_size)` **before** the VMA lookup, and `vm_sigsegv` (`:2345`) prints that
aligned value, so **every** slow-path fault message is page-aligned regardless of cause. The fast
path (`fast_sigsegv_check`) prints the **raw** unaligned address.

What failed: I argued that an exact-page-boundary fault address proved a page-granular reclaim
event. It was a tautology. What worked: reading `core/mmu.cc:2457` and `vm_sigsegv`, then reasoning
about which path prints aligned vs raw.

## [correction] Pagecache/ARC reclaim cannot SIGSEGV a mapped file page

Reclaim only **clears PTEs** (`core/pagecache.cc:229/296` `clear_pte`, `:397` `cp->unmap`) and
**never removes a VMA**. A cleared PTE under a live `file_vma` is serviced transparently by
`vma->fault()` (`core/mmu.cc:2511`) - a demand-paging round trip, not a crash.

Additionally, under `conf_zfs=openzfs` the ARC read cache is **unreachable**: patch 0005 removes
`ZFS_ID` from `m_fsid` so `IS_ZFS()` is false, `arc_read_cache` is never populated, and
`unmap_arc_buf`/`remove_arc_read_mapping` are only reachable from `bsd/porting/mmu.cc:56`
(legacy bsd_zfs).

What failed: I banked an ARC-reclaim mechanism as CONFIRMED and briefed a fix to harden the
pagecache unmap path, citing line numbers in code that config disables by design. What worked: an
agent refuted it at source level *before* implementing, and a reproducer on `fs=rofs`
(`vop_cache = nullptr`, no pagecache at all) still faulted - excluding reclaim structurally rather
than by argument.

**General rule: check whether the lines you cite can execute in the configuration under test.**

## [insight] Instrument trap: msync vs mincore

Do **not** use `msync()` to test whether a VMA exists in an address space. `core/mmu.cc:2984`
`file_vma::sync()` returns `ENOMEM` for any mapping without `mmap_shared`, so it reports "not
mapped" for a correctly mapped `MAP_PRIVATE` library segment (false negative).

Use **`mincore()`**: `mincore()` -> `ismapped()` -> `find_intersecting_vmas()` -> `cur_vma_list()`
consults the same per-AS list the fault slow path searches.

## [insight] PostgreSQL-on-OSv substrate invariants (each has voided a run)

1. `image=zfs` **alone selects legacy bsd_zfs** (`modules/zfs/module.py` defaults
   `conf_zfs=bsd`), where ashift is hardcoded to 9 (`vdev_disk.c:91`) and every ZFS property is
   ignored. Pass `conf_zfs=openzfs` and **prove it at runtime** via the guest banner
   `zfs-2.4.1-osv`.
2. Do **not** pass `open_zfs` explicitly: its `provides=['zfs']` shadows the placeholder and drops
   the `/usr/lib/fs/libsolaris.so` manifest line ("Failed to preload ZFS library").
3. `apps/postgres18-musl/module.py` defaults PGDATA to **ramfs**
   (`--mount-fs=ramfs,/dev/null,/data`) and must be overridden.
4. **In-guest `initdb` is impossible**: OSv stubs `popen()`, so initdb's `postgres -V` check fails.
   initdb on the host, bake read-only, `seed_copy` into the dataset.
5. `cpiod.so` is absent from non-builder images **by design** (only
   `zfs_builder_bootfs.manifest.skel` packages it).
6. ZFS pool needs a raw virtio-blk disk with **default 512-byte logical blocks** plus `ashift=12`.

## [insight] Boot substrate: the q35 hang

OSv x86 does **not** boot under QEMU `-M q35`: ich9-ahci presents an empty ATAPI CD on port 2, OSv
issues ATA IDENTIFY **unconditionally**, ATAPI aborts it, and per **AHCI 1.3 s6.2.2** `PxCI` is
never cleared, so `wait_ci_ready`'s unbounded `for(;;)` spins forever. It is
**machine-type-independent**: `pc + ich9-ahci + ide-cd` also hangs. AL2023's qemu 11 ships **only**
q35 (i440fx compiled out, `-M pc` -> `unsupported machine type`), which is why host qemu 11 appears
unable to boot OSv at all. Fix in **PR #1498**. Workaround: fedora:39 container qemu 8.1.3 with
`-M pc`.

`PORT_IS_TFES` is defined at `ahci.hh:107` and **never checked**; `wait_cmd_poll` acks `PxIS`
*before* examining it, destroying the error record.

On aarch64: boot `-kernel loader.img` (`loader.elf` dies at `premain: failed to get TLS data from
ELF`), and the root disk is **qcow2** - forcing `format=raw` gives a misleading "Cannot find the
pool label".

## [user_input] Benchmarking discipline (from the user, twice)

Only the independent variable may differ. **PostgreSQL version parity is a GATE, not a caveat to
footnote.** Match PG major+minor (`REL_18_STABLE`, 18.6), the configure line, and **`io_method`
(= `sync`**, because OSv's AIO path is incomplete and Linux/PG18 defaults to `worker`).

**Result identity is the tuple (osv SHA, apps SHA, zfs banner, PG branch, PG version, configure
line).** Never use `/tmp` or tmpfs for data. Never disable `fsync` or `autovacuum`. Mimic a
production configuration. Get statistically valid results (>=3 repeats, flag >15% spread).

## [insight] OSv-vs-Linux PostgreSQL findings

**`LWLock:WALWrite` dominating is NOT an OSv defect.** It reproduces on Linux/PG18.6 at **55 of 64
backends** - but there with the NVMe **73-93% utilised**, whereas OSv showed the same queue with
the device **98% IDLE**. The discriminator is **`%util` alongside the wait event**, never the
wait-event name alone.

- Linux reference peaks at **99,504 NOPM at VU8 and declines after** (no scaling region).
- Linux connect probe: 4350 samples, **zero >= 1 s**, worst 17.6 ms. OSv aarch64: **262 ms
  median**. That ~65x gap dwarfs the musl-vs-glibc and geometry confounds.
- **`checkpoint_timeout=15min` never fires** under 200-warehouse load (`num_timed=0`, 49/51
  checkpoints WAL-triggered every ~72 s), which **structurally** causes 30-35% run-to-run spread.
  Raise `max_wal_size` or lengthen the run.
- **ZFS costs 3.9x on the 8 KiB dsync WAL pattern** (56.1 vs 218 MB/s raw), so splitting WAL to
  `recordsize=1M, logbias=throughput` is the obvious next lever for both platforms.
- `m5d.4xlarge` has **two** instance-store NVMe devices; a single-device pool leaves one idle.

## [insight] Process lessons about running agents

- **A stalled agent is not a dead agent.** Detect stalls by elapsed-vs-tool-uses (18 calls in
  19.5 h = blocked), not elapsed time alone. Both "stalled" agents later did useful work.
- **Never hand a live agent's box to a replacement** without telling both. Doing so twice created
  two-agents-one-box collisions; both were caught by the agents, not by me. Tag boxes with
  `Owner=agent-<id>`.
- **Give agents full filenames, never paraphrases.** "the HammerDB RHEL9 build" sent agents to
  404s; the real asset is `HammerDB-6.0-Prod-Lin-UBU24.tar.gz` / `-Prod-Lin-RHEL9.tar.gz`.
- **Name the exact reference document.** "Match the OSv arms" sent an agent to a stale
  `HAMMERDB-BENCHMARK.md` recording a superseded 40-warehouse config.
- **The winning debugging method, every time it worked, was reproducing the mechanism in
  isolation.** A 60-line C program beat every bare-metal HammerDB sweep for diagnostic value.
- **`git merge-base --is-ancestor <fix> <branch>`** before concluding anything is broken; four
  "bugs" this project chased were stale bases.
- GitHub's `mergeable` flag reports **false conflicts** here because it does not apply
  `.gitattributes` merge drivers. Only `git merge-tree` from a worktree checked out at
  `upstream/master` is authoritative.

---
# Additions from 2026-09-09/10 (memelord still down: `Connection closed (GenericFailure)`)

## [insight] The psABI TCB defect (now upstream PR #1504)
`arch/x64/arch-tls.hh`'s `thread_control_block` was **3 words = 24 bytes**, but the x86-64 psABI puts
the `-fstack-protector` canary at **`%fs:0x28`** (40) and the pointer guard at `0x30`. Both fall past the
struct **and past its allocation** (`arch-switch.hh:385` sizes it `total_tls_size + sizeof(*_tcb)` and
places the TCB at the very end). So **every canary check by an app built with the protector was an
out-of-bounds heap read**, returning page-table-shaped values (`0x802000006812d065` = NX|present|user|
accessed|dirty). Invisible because the kernel is `-fno-stack-protector`; fatal under fork because a child
resumes mid-frame carrying the parent's spilled canary while re-reading its own OOB slot. Fix: extend to
cover 0x28/0x30, `static_assert` the offsets, initialise both guards, and keep the value **process-wide**
(a per-thread canary is unsound when one context resumes on another's frame). **Present on pristine
master.**

## [correction] "No application needs it" is not a reason to skip a POSIX rule
I let an agent answer a reviewer by conceding a `fork()` fd-semantics gap and arguing no application
needed it, then endorsed that. **For a project whose purpose is Linux-ABI compatibility, the POSIX rule
IS the specification.** Absence of a complaining application is at most an argument about priority.
Correct standard: implement the POSIX behaviour first, deviate only where Linux-ABI compatibility
genuinely conflicts, and say so explicitly when deviating.

## [insight] POSIX fork() fd semantics, the half that gets broken
The child gets a **copy of the table** where each fd refers to the **same open file description**. So:
`close()`/`dup2()`/`FD_SETFD` are private, numbering is independent, **but the offset, `O_NONBLOCK` and
locks are SHARED**. `FD_CLOEXEC` is per-descriptor; the offset is per-description. Implement as: table
object + pointer in the thread + clone-on-fork taking a reference (`fhold`) per open file + per-table
CLOEXEC bitmap. `pthread_create` threads **share** their creator's table. **A naive "duplicate
everything" fix passes the independence tests and silently breaks shared offsets** - test that
explicitly.

## [correction] Scope is a property of the (base, branch) PAIR, never of the branch
I claimed `wip/fork-clone-scan` was "2 commits" then "8 commits". Both were true - against different
bases. Measured against the x86 base it is 2 (+211 lines, mmu.cc only); against the aarch64 base, 8
(also `mempool.cc` +62, `virtio-blk.cc` +24). **Re-measure per base with `git log base..branch` plus a
diffstat.** And separately: **`git merge-tree` reporting zero conflicts proves the branch MERGES, not
what it contains.** Mergeability is not scope.

## [correction] Never describe a PR's code from the working tree
Three times this session I attributed integration-branch content to a PR head, once writing a brief that
told an agent to delete three hooks that **do not exist on that base**. Guard: **`git show <pr-head>:<file>`
before making any claim about a PR's code**, plus `git merge-base --is-ancestor <fix> <branch>` before
concluding anything is present or broken.

## [insight] A retraction must land in THREE places
The PR **body**, the **commit message**, and the **code** - each verified separately. A body is editable
forever; **a commit message is what gets merged into git log permanently**, so a retraction that lands
only in the body does not survive the merge. Found two live instances (#1476, #1447). Related defect
class: **a published correction that was never landed** (#1497 sat for a day with code its own correction
comment had retracted). Neither is detectable by review, merge-tree, or a leak scan - only by comparing
the thread against the head, and the head against every commit message on it.

## [insight] A PR's head branch is NOT editable on GitHub
`PATCH /repos/.../pulls/{n}` accepts `head`, returns **200**, and **silently discards it**. Proven with
controls: a nonexistent branch also returns 200 and is also ignored, while `base=master` on the same call
works. **So "retarget this PR" is never a valid recommendation** - the options are force-push or
recreate. This had been standing advice in a thread for weeks and was never actionable.

## [insight] Substrate rules for OSv+PG benchmarking, round 2
- **`conf_zfs=openzfs` does NOT select the OpenZFS image path - only `--use-openzfs` does**
  (`scripts/build:176,340,372`). Without it, image assembly boots a guest and pushes ~112 MB over
  `cpiod`, which wedged 4/4 attempts. `scripts/upload_manifest.py:194` **hardcodes `-m 4G`**, so
  `zfs_builder_mem` is inert.
- **`fs=rofs` images are ~119 MB / 6 manifest entries**; the PostgreSQL-free failure signature is **~8 MB**.
  (An earlier 63-65 MB figure was a different fs - calibrate the check to the fs in use.)
- **`vhost=on` leaves the guest unreachable** (binds the IP, logs `eth0:`, never answers ARP). Use
  `vhost=off`. **`--norandom` breaks PG** ("could not generate random cancel key"). **`ashift` needs
  `zpool get`, not `zfs get`.**
- **`git submodule update` silently reverts `apps` to the upstream pin and re-arms the shadowed-build
  trap** - re-check `grep -c 'PHONY: module build'` = 1 after ANY submodule operation.
- **`apps` must be `5cb1903`, not `b38b99cd`** - the latter lacks the `.PHONY` fix and yields a
  PostgreSQL-free image reporting success.

## [insight] The instrument lies more often than the code
Three separate false signals this campaign, none in the code under test: **`msync`** reports ENOMEM for a
correctly-mapped MAP_PRIVATE segment (use `mincore`); **`echo` after a failed `git push`** printed
success because it ran regardless of exit status; **`free -g` inside a cgroup** shows the whole host
because `/proc/meminfo` is not namespaced (use `memory.max`/`memory.peak`). Also
**`pg_stat_activity.state='active'` means "not on a registered wait event", NOT "on CPU"** - a
"CPU-bound" verdict from it was wrong by 60x. **Choose instruments whose failure mode you understand.**

## [insight] Benchmark methodology corrections
- The old Linux baseline **understated Linux by ~2.3x** (16-vCPU VM + glibc vs OSv on 32-vCPU metal +
  musl). Matched: **VU8 213,505 -> VU64 614,277 peak**. **Linux SCALES to VU64; OSv peaked at VU8**, so
  the gap runs **4.9x at VU8 to 21.6x at VU64**. **Always attach the VU level to a ratio** - a bare "Nx"
  is meaningless when it quadruples across a sweep.
- **"No scaling region on Linux either" was a 16-vCPU saturation artifact**, generalised from one
  handicapped configuration.
- A **cgroup `MemoryMax` does not cap ZFS ARC** (host kernel memory, not charged to the cgroup). Uncapped,
  Linux would have had a **~377 GiB cache against a 64 GiB guest**. Set `zfs_arc_max` and **prove limits
  BIND under load** (`memory.peak`, `arcstats`), because a limit that never binds proves nothing.
- **`max_wal_size=64GB` is throughput-dependent**: 6 timed / 0 requested at ~43k NOPM, but **1 timed / 18
  requested at 614k**. Confirming a mechanism is not the same as confirming the diagnosis.
- **`m5zn.metal` is ~4.5 GHz vs m5d's ~3.1 GHz** - a host swap can silently flatter a result.

## [insight] Running agents: three orphans in one session
All three died of context exhaustion with **unpushed work still on the box**, and all three were
recovered only because the box was inspected before termination. **Salvage-then-reclaim is the standing
order**, and the salvage must check **local worktrees too**, not just the box and the remotes (one
"missing" implementation was sitting uncommitted in one of 23 local worktrees). Standing brief rule now:
**push a branch as soon as the implementation compiles**, before testing finishes, and re-push after each
step. Detect stalls by **elapsed-vs-tool-uses**, not elapsed time alone.
