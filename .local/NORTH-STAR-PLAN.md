# North-star plan: PostgreSQL at scale on OSv + OpenZFS, and a matured OSv

Written 2026-08-31. Living plan. Two goals, in priority order when they conflict:

- **G1 (application):** stock, unmodified PostgreSQL running at high performance
  and scale on OSv over OpenZFS, on local NVMe, on bare metal and micro-VMs,
  across x86_64 and aarch64.
- **G2 (platform, the broader win):** every fix is a GENERIC OSv improvement that
  is upstreamable and benefits all OSv workloads. G1 is the forcing function; G2
  is the deliverable. A PG-specific hack that does not generalize is a failure
  even if it makes a number go up.

## CURRENT PHASE STATUS (rewritten 2026-09-11, maintenance round 13)

> The round-12 (2026-09-10) version of this section is superseded by this one and
> marked below. What changed today: the `__stack_chk_fail` blocker is **fixed and
> filed as #1504**, a throughput benchmark is **in flight** rather than blocked,
> **three** master-eligible PRs now exist (#1502/#1503/#1504), and the three
> pre-existing #1455 defects are characterised with a four-column matrix.

Upstream `master` is **0e34e4dc2, unmoved since 2026-08-17** (re-verified
2026-09-11). The maintainer has been offline, so every merge is blocked.
**"Not merged" here means "not reviewed yet", NOT "rejected".** **51** PRs are
open; **0 have an unanswered human comment** as of 2026-09-11, verified by
walking both comment APIs (issue comments AND review comments) with reply-ID
threading across all 51.

### Master-eligibility: THREE PRs, not four

**#1502** (VFS AB-BA deadlock), **#1503** (per-chain dentry locks, stacked on
#1502) and **#1504** (psABI TCB stack/pointer guards) are the **first
non-fork-gated, master-eligible PRs of the entire programme**. Verified
2026-09-11: all three `base=master`, all three merge-tree exit 0 against
`0e34e4dc2`, none bit-rotted, and **zero `CONF_fork`/`conf_fork`/`OSV_FORK`
references in any of their diffs** (the positive test for non-fork-gating).

There is **no fourth**. An earlier count of "four" was a miscount of a
three-item list.

### Throughput: IN FLIGHT, not done and not blocked

The `__stack_chk_fail(): Stack overflow detected` blocker that killed five
consecutive throughput attempts is **fixed** and is now PR **#1504** (`x64:
cover the psABI stack and pointer guards in the thread control block`). A
benchmark is **running concurrently** under `Owner=agent-a2abench` on metal.

**Throughput on a fixed base therefore remains UNMEASURED.** Report it as work
in flight. Nothing in this plan credits that benchmark's results; whatever it
finds supersedes the gap figures below.

### The three pre-existing #1455 defects (four-column evidence)

Found while implementing the POSIX fd table; all three are **pre-existing in
#1455, not introduced**. Detail in `.local/FORK-1455-THREE-DEFECTS.md`.

1. **`conf_fork=1` never linked.** `config fork` was a plain `bool` with no
   `def_bool $(shell,...)` hook while `Makefile` gated on the make variable, so
   both the real `fork()` and `runtime.cc`'s stubs compiled: `multiple
   definition of 'fork'`. **The documented enable path has never built**, a
   plausible reason the PR sat.
2. **Callee-saved registers never restored in the fork child.** The child
   installed the copied stack (`movq %0, %%rsp`) and resumed with the new
   thread's `rbx`/`rbp`/`r12`-`r15`, while the frame it landed on was compiled
   expecting the parent's.
3. **The shared global fd table.** One `gfdt[]` for all processes, so a child
   could not hold independent descriptors and `close()` in a child page-faulted
   in `fdclose()`.

The four-column matrix is the load-bearing part, because it refutes the
obvious shipping shortcut:

    base dce0d32fd            guest CRASH (fdclose page fault)  nothing testable
    +kconfig +regfix          1/6   t2_offset_is_shared passes => regfix is sound
    +kconfig +fdtable         0/6   the fd table ALONE is worthless
    all three                 6/6   the series is the unit

Shipping "kconfig + fdtable" (the proposed default) measures **0/6**, so it
would have claimed 6/6 for something that fixes nothing. **#1455 stays DRAFT**
with a disclosed `tst-execve` regression on commit 2 and a documented
outermost-frame limit of a relocating stack copy.

### The kconfig hook is NOT a standalone upstream PR

Checked 2026-09-11 with positive evidence rather than inference:

    git grep -n 'config fork' upstream/master -- conf/   -> exit 1, no output
    git grep -n 'conf_fork'   upstream/master            -> exit 1, no output
    git grep -n 'CONF_fork'   upstream/master            -> exit 1, no output

Master has **no** `config fork` at all, so the plain-`bool` defect is introduced
by #1455 itself and `aff774350` is a self-fix within that series, not an
independent upstream defect. (`conf/kconfig/threads` does exist on master, which
is what made this worth checking.)

### SOLVED 2026-09-10: connect latency, on BOTH ISAs, and the fix is architectural

The large-page fork port closes the connect-latency wall on both instruction sets,
and the mechanism counters match to 0.1%, which is what makes this conclusive
rather than suggestive:

    ISA        connect latency          n_ptes before -> after    ratio
    aarch64    117.3 -> 3.98 ms         4,445,585 -> 132,497      33.6x
    x86_64      56.9 -> 6.60 ms  8.61x  4,445,538 -> 132,962      33.4x

aarch64 now lands inside the Linux band (4.0-4.3 ms). `n_ptes` is a
**hardware-independent counter**, so the near-identical before/after counts on two
different ISAs prove the same code path does the same work: **the fix is
architectural, not ISA-specific.** The counters are the durable evidence; the
milliseconds are host-specific (the x86 box is higher-clocked than the baseline
class and the probe includes a TCP round trip, so the ratio travels and the
absolute numbers do not).

Branch: `gh-fork/wip/pg-x86-forkroot-largeshare` @ `42aeb163b` (x86),
`gh-fork/wip/forkroot-arm-base` @ `5a8e946f0` (aarch64). Both tips are the SAME
`core/mmu.cc` commit content (`3364d5c68` == `5a8e946f0` by tree comparison).

### STILL UNMEASURED: throughput on a fixed base -- PARTLY SUPERSEDED by round 13

> **Updated 2026-09-11.** The count is **five** failed attempts, not four. The
> `__stack_chk_fail` blocker described here is **FIXED** and filed as **#1504**;
> a benchmark is in flight under `Owner=agent-a2abench`. Throughput itself is
> still unmeasured. See "Throughput: IN FLIGHT" at the top.

**Four consecutive attempts have failed to produce a throughput number on a fixed
base.** The current blocker is `__stack_chk_fail(): Stack overflow detected` after
**1-5 cumulative `fork()` calls** (agent in flight, `Owner=agent-stackchk`).
Characterised rather than guessed: independent of the perf ports (both A/B arms
crash identically 6/6), independent of query work (500k inserts + full update +
71k deletes + VACUUM + CHECKPOINT on one held connection, zero crashes, and the
**next new connection** killed it), and independent of concurrency (8/8, 16/16,
32/32, 96/96 simultaneous connections all fine from a fresh boot). Working
hypothesis is that all forked children share ONE musl pthread struct including
the canary slot at `%fs:0x28` (`.local/STACKCHK-DIAGNOSIS.md`).

**So the standing gap figures below are still the older-base ones. Do not report
throughput as improved by the latency fix; that is exactly the claim that is
unmeasured.**

### The standing gap, and the SHAPE question that matters more than the level

    VU     Linux NOPM      OSv x86      gap
     8     213,505         43,407       4.9x
    64     614,277 PEAK    28,377      21.6x

**Linux scales to VU64; OSv peaked at VU8.** The gap widening 4.9x -> 21.6x is a
difference in SHAPE, not in level, and that is the open question: do the fork and
VFS fixes change the shape, or only the level? A single "Nx" figure misrepresents
this and should not be quoted alone. (See also the corrected baseline section
below: against the geometry-matched Linux reference the VU8 gap is 5.3x.)

### FIRST MASTER-ELIGIBLE PRs OF THE WHOLE PROGRAMME -- SUPERSEDED by round 13

> **Superseded 2026-09-11.** The list is now **three**: #1502, #1503 **and
> #1504**. See "Master-eligibility: THREE PRs, not four" at the top.

**#1502** (VFS AB-BA deadlock between `dentry_hash_lock` and the vnode lock) and
**#1503** (per-chain dentry locks, stacked on #1502) are the **first
non-fork-gated, master-eligible PRs of the entire programme**. Everything else
has been confined to #1456 comments because master has no `fork()`. Both verified
2026-09-10: `base=master`, merge-tree exit 0 against `0e34e4dc2`, no bit-rot.
An AB-BA inversion is a defect with or without fork; fork merely supplied enough
concurrent `open()`/`drele()` traffic to hit it.

### The fork-arena container class is now at FOUR instances, not three

`.local/FORK-ARENA-GLOBAL-CONTAINER-CLASS.md` names the invariant. Instances now:
`struct file`/`f_epolls`/thread objects, `core/epoll.cc`, `elf::program`'s
`_files` cache, `fs/rofs/rofs_cache.cc` `global_file_cache` (third), and
`core/pagecache.cc`'s three shared caches (fourth, `9aa67d72f`). The rule is
documented in-tree at `core/epoll.cc:63-81`. **This should drive an audit of the
remaining process-global lazily-populated containers, not more one-offs.**

### SUBSTRATE CORRECTIONS -- standing rules, verified, cite these

These are cheap-to-forget facts that have each cost real time:

1. **`conf_zfs=openzfs` does NOT select the OpenZFS image path.** Only
   `--use-openzfs` does (`scripts/build:176,340,372`). Setting `conf_zfs` alone
   and expecting an OpenZFS image is a silent wrong-image trap.
2. **`upload_manifest.py:194` hardcodes `-m 4G`.** Image-builder guest memory is
   not inherited from your environment.
3. **`fs=rofs` gives ~119 MB / 6 entries.** The PostgreSQL-free signature is
   ~8 MB. Image size is a reliable smoke test.
4. **`vhost=on` leaves the guest unreachable.** Do not enable it and then debug
   the network stack.
5. **`ashift` must be read with `zpool get`.** Do not infer it.
6. **`--norandom` breaks PostgreSQL.**
7. **The `apps` pin is load-bearing and has two distinct traps.** `b38b99cd`
   silently yields a **PostgreSQL-free image that reports success** (the
   `build`-target shadowing bug: `module: build` depends on a target named
   `build` while `build.sh` creates a real `build/` directory, so without
   `.PHONY: build` make skips the recipe and exits 0). `57c6079...` is a
   **dangling** gitlink that exists in no repository. The good pin is
   **`5cb1903`**, which carries the `.PHONY: module build` fix.

## Where we are (2026-08-31) -- SUPERSEDED, KEPT FOR HISTORY ONLY

> **Do not cite this section.** Read "CURRENT PHASE STATUS" below instead. Every
> throughput number in this paragraph was measured on a base whose `apps`
> submodule pin (57c607984393) points at a commit that exists in no repository,
> so their provenance is unrecoverable; and the crash-boundary claim is void (it
> was the ELF/dlopen bug, which reproduces at 1 connection, not a VU ceiling).
> The ">=4 GB memory-map bug" is now FIXED and shipped as #1490.

Achieved: 28 PRs merged upstream. PG18.6-on-OpenZFS runs unmodified on x86_64
(bare metal + Firecracker) and aarch64 (Graviton3), beats the Linux baseline at
peak (~248k NOPM VU32 bare metal; 145k VU16 Firecracker = 2.9x Linux VU8), is
crash-free through VU192 (autovacuum off) / VU128 (autovacuum ON), and degrades
gracefully rather than crashing past that. Production autovacuum works.

Not achieved: tail latency is untuned (all optimization targeted throughput);
aarch64 is not benchmarked (a >=4 GB memory-map bug caps it at 3 GB); several
OSv/FC/PG knobs never swept; PGXN extension coverage (M2) not started.

## CURRENT PHASE STATUS (rewritten 2026-09-09, maintenance round 11) -- SUPERSEDED by round 12 above

> **Superseded 2026-09-10.** Read the round-12 "CURRENT PHASE STATUS" at the top
> instead. Kept for history: its gap figures and blockers were correct as of
> 2026-09-09, but connect latency is now SOLVED on both ISAs and #1502/#1503 now
> exist as the first master-eligible PRs. The "53 PRs are open" count is stale;
> it is 50.

> The 2026-09-08 version of this section is superseded by this one. Its
> *structure* was right; every **gap figure** in it was measured against a
> handicapped Linux baseline and is corrected below.

Upstream `master` is **0e34e4dc2, unmoved since 2026-08-17**. The maintainer has
been offline, so every merge is blocked. **"Not merged" here means "not reviewed
yet", NOT "rejected".** 53 PRs are open; 0 have an unanswered human comment.

### THE HEADLINE CHANGED: the gap is 5.3x / 11.5x, not 2.3x / 4.9x

A geometry-matched and libc-matched Linux baseline on bare metal measures
**232,139 NOPM @ VU8**, against the old 16-vCPU-VM reference of **99,504**. The
old reference understated Linux by **2.33x**.

    reference                            NOPM @ VU8    OSv gap
    Linux, 32 logical metal, musl          232,139     (baseline)
    Linux, old 16-vCPU VM, glibc            99,504     VOID as a comparator
    OSv x86_64                              43,407     5.3x behind   (was "2.3x")
    OSv aarch64                             20,121     11.5x behind  (was "4.9x")

**Removing the confounds did not flatter OSv.** Every gap figure in every doc in
this project predating 2026-09-08 was measured against the handicapped baseline
and should be read as such.

The residual asymmetry **favours OSv**, so the gap is if anything understated:
Linux ran with a **hard 16 GiB ARC cap** (`size` 17,224,108,416 against `c_max`
17,179,869,184, pinned at the ceiling all run) while the OSv guest gets **~32
GiB**. Linux had half the cache and was still 5.3x faster. That pre-empts the
obvious objection to the whole result.

**Consequence for the north star: M1 parity is much further away than believed.**
P1/P3 knob-level work cannot close a 5.3x gap; the remaining distance is
structural (see the unattributed stall and the fork cost below), not tuning.

### Work IN FLIGHT right now (not done, do not report as done)

Three agents are running concurrently as of this writing:

1. **fork root-cause on aarch64** (`Owner=agent-forkroot`). Testing whether fork
   latency is the single root cause behind the aarch64 VU32 ceiling, the ~100 ms
   connect latency, and fork starvation. Its EC2 box is already gone; scratch is
   in `.forkroot/`.
2. **AIO / `io_method=worker`** (`Owner=agent-aio`, one bare-metal box).
   Source reading says PG18's `io_method=worker` needs no kernel AIO and the
   blocking build comment is stale; hardware proof pending. Already pushed two
   one-line fixes to osv-apps#73 today.
3. **Firecracker + wedge backtrace + musl baseline** (`Owner=agent-fcmetal`, one
   bare-metal box plus a driver box).

Nothing below credits their results. Anything they find supersedes this section.

### P0-P5 STATUS AT A GLANCE (2026-09-09)

| phase | state | blocked on / note |
|---|---|---|
| **P0** upstream hygiene | **FINISHED** | - |
| **P0.4** fresh benchmark base | **BLOCKED** | maintainer decision on how #1455/#1456 compose (add/add, not an increment) |
| **P0.5** extract buried fixes | **FINISHED** | - |
| **P1** p99 / latency | **BLOCKED** | the unattributed stall; no valid p99 base exists on either ISA |
| **P2** aarch64 | **PARTLY DONE, re-blocked** | fork cost; agent in flight |
| **P3** knob sweep | **UNSTARTED** | needs a base that survives to steady state |
| **P4** PGXN extensions | **UNSTARTED** | same dlopen/ELF surface |
| **P5** durability | **PARTLY DONE, unplanned** | fragmentation cliff unmeasured on any valid base |

### What is GENUINELY FINISHED

- **P0.1 (#1449 ext4 security rebase): DONE.** `pr/sec-ext4-readlink` merges clean
  into 0e34e4dc2 by dry-run merge-tree (exit 0), despite GitHub still showing
  CONFLICTING. GitHub's flag is stale/wrong here.
- **P0.2 (#1447 rebase): DONE as `pr/ext4-perf-v2`.** Verified again 2026-09-09:
  `pr/ext4-perf-v2` contains af27ba4b7 and merges clean (merge-tree exit 0); the
  PR's own head `pr/ext4-perf` does NOT contain af27ba4b7 and conflicts in
  exactly 3 files (`.gitignore`, `modules/libext/ext_vnops.cc`,
  `tests/tst-ext4-rw.cc`). Re-validating the perf numbers is NOT done (blocked).
  **CORRECTION 2026-09-09: "only the PR's head pointer is stale" implied a fix
  that does not exist.** A PR's head branch is **not editable on GitHub**:
  `PATCH /repos/{owner}/{repo}/pulls/{n}` accepts a `head` field, returns 200,
  and silently discards it (verified with two controls: a nonexistent branch name
  is accepted and ignored identically, while `base` on the same call works). The
  two branches are divergent rebases of a common ancestor, so no fast-forward
  exists either. **So "retarget this PR to that branch" was never actionable, by
  anyone.** When the re-measurement happens, #1447 must be **recreated as a fresh
  PR**, not repointed. Also disclosed on the PR body this pass: the withdrawn
  write-parity claim still survives in commit message `f20b91d75` (and as
  `4ca6429df` on v2), so the rewrite has to happen as part of that recreation.
- **P0.3 (reviewer hygiene): DONE and re-verified this pass.** Every human review
  thread from nyh and wkozaczuk across all 47 PRs has a gburd reply after the last
  human message. #1464 is APPROVED and still merges clean.
- **P0.5.1 (bootfs_dep gap): DONE**, shipped as #1494/#1496 (and #1495 makes a
  failed OpenZFS patch series fail the build instead of silently continuing).
- **P0.5.2 (extract buried generic fixes): DONE and productive.** #1490, #1491,
  #1492, #1493 all came out of the fork mega-commits. The aarch64 three (#1490/
  #1491/#1493) were independently validated on real Graviton3 hardware: a
  32-vCPU/64 GB guest boots with them and cannot boot without #1491.
- **P5 (durability), PARTIALLY and unplanned: real evidence exists.** On aarch64,
  ZFS+PG recovered cleanly from both a kernel crash and a `kill -9` mid-load;
  140,000,000 rows and the full 200-warehouse dataset verified intact after
  recovery, dataset persisted across reboots via `zpool import`. This is the first
  genuine durability evidence in the program and it came from crashes, not a test.
- **The fork/dlopen address-space bug CLASS: root-caused, 3 instances handled.**
  `.local/FORK-ARENA-GLOBAL-CONTAINER-CLASS.md` names the invariant instead of
  patching cases one at a time: under `conf_fork=1`, any container that is
  **process-global** but **populated lazily by whichever address space touches it
  first** ends up with nodes that are garbage in every other AS, and the first
  free from a different AS aborts the VM (`h->magic == chunk_magic`). The in-tree
  rule is `fork_arena::kernel_heap_scope` (documented at `core/epoll.cc:63-81`, a
  no-op in a non-fork build). Instances: `struct file`/`f_epolls`/thread objects
  (already handled), `core/epoll.cc` (handled), and `elf::program`'s `_files`
  cache (fixed, runtime-validated on both ISAs). **This should drive an audit of
  the remaining process-global lazily-populated containers, not more one-offs.**
- **The `conf_fork=0` build break: FIXED on all three affected branches** and
  re-verified 2026-09-09 (the `class file` override now sits inside `#if
  CONF_fork` on `ff7fba040`, `37e3912ac`, `7aa9c577c`). No open PR was ever
  affected. A cheap standing check is proposed under P0.5 below.

### What is BLOCKED, and on exactly what

- **P1 (p99/latency): BLOCKED, and the stated blocker below is SUPERSEDED.**
  **UPDATE 2026-09-09.** The dlopen/ELF crash that stopped the 2026-09-07 arms is
  **fixed and validated on both ISAs** (see P2), so it is no longer the live
  blocker. Both arms now reach a timed window and NOPM tables exist. What blocks
  p99 now is the **unattributed stall** plus the **x86 silent wedge**: at VU32 the
  device is 12-19% utilised, `LWLock:WALWrite` holds only 1-5 of 32 backends, and
  the guest still consumes ~0.5 of 32 vCPU, so the tail is being set by something
  OSv does not surface as a PG wait event. No p99 conclusion is available and no PG
  knob can be blamed yet.
  Retained for history: the ELF-page-reclaim bug (`.local/ELF-RECLAIM-BUG-CONFIRMED.md`),
  `pagecache.cc remove_read_mapping` unmapping file-backed pages unconditionally.
  NOT filed upstream by instruction; fix design owned by the program maintainer.
  Note `.local/ELF-RECLAIM-BUG-RETRACTED.md` also exists; reconcile those two
  before acting on either.
- **P2 (aarch64): PARTLY DONE, then re-blocked, and now PARTLY UNBLOCKED again.**
  **UPDATE 2026-09-09.** P2.1 is done and shipped (#1490 covers the >=4 GB
  phys-map bug; 64 GB guests boot). The dlopen/ELF blocker named below is
  **root-caused and fixed**: `elf::program`'s `_files` object cache is
  process-global while PT_LOAD mappings are per-address-space, so a cache hit
  returned a `_base` mapped in no current AS
  (`.local/FORK-DLOPEN-AS-CACHE-BUG.md`, proven with a 60-line C reproducer and
  no PostgreSQL). The fix is runtime-validated on **both** ISAs via
  `tests/tst-fork-dlopen-as.cc` (pre-fix: page fault at
  `elf::object::dynamic_tag+12`; post-fix: rounds 0..11 pass plus the
  parent-as-second-consumer case).
  **P2.3 now has real aarch64 throughput for the first time: peak 20,121 NOPM @
  VU8**, with all 6 TPROC-C plpgsql procs running under load for the first time in
  the program's history. But **VU32 is a hard ceiling** (no result in 4 attempts)
  and VU8/VU16 spreads are 27.6%/29.7%, so they **fail the 15% gate** and are not
  publishable medians. Now blocked on **fork cost** rather than on a fault: ~100 ms
  connect latency against Linux's 4.0-4.3 ms, matching the measured 65-150 ms/fork,
  which plausibly unifies the VU32 ceiling, connect latency and fork starvation into
  **one** root cause (`.local/ROOT-CAUSE-HYPOTHESIS-FORK.md`). **An agent is
  investigating this right now**; do not treat it as settled either way.
  P2.2 (splitting the aarch64 fork-COW branch) is still unstarted.
- **A new x86 blocker appeared: a silent wedge under load** (`.local/X86-WEDGE-2026-09-08.md`).
  Guest stops serving with the last console line a `checkpoint starting: time`
  that never completes; TCP :5432 still accepts but no query returns; device
  0.00% util; **zero page faults in 68,751 console lines**. That last datum is
  decisive that it is **not** the ELF/dlopen bug just fixed. Plausibly the same
  family as the unattributed stall. Unfixed, and it caps x86 runs.
- **P0.4 (fresh benchmark base): STILL THE GATE, and the reason is unchanged.**
  master has no fork() at all; PG needs fork; #1455 merges clean onto master but
  #1456 does NOT stack on it (add/add on `libc/process/fork.cc`, `arch/*/fork.cc`,
  `include/osv/fork.hh`), meaning #1456 is a revised presentation of #1455's work,
  not an increment. How they compose is a maintainer question. Confirmed again this
  pass: #1455 CLEAN, #1456 CONFLICTING by merge-tree.

### What is UNSTARTED

- **P3 (knob sweep).** Still effectively unstarted. It needs a base that survives
  to steady state; x86 now reaches a timed window but the silent wedge still ends
  runs, and aarch64 cannot pass VU32. **#1476 is CLOSED as of 2026-09-09 and is
  superseded by #1501** (same code, corrected commit message). The knob is
  measured after all, and the honest result is that it is **host-conditional**:
  halt VM-exits collapsed 48975/s -> 434/s on one host and were unchanged
  (57692/s -> 58084/s) on a later host whose KVM halt-polling already caught
  those wakes. So it is an efficiency lever, not a throughput lever, and P3 should
  not budget uplift for it.
- **P4 (PGXN extension coverage).** Unstarted. The dlopen/ELF gate that made this
  hopeless is **fixed**, so this is now genuinely startable once a base survives
  to steady state. Extension loading is exactly the surface the fix repaired.
- **P5 remainder.** The fragmentation cliff past VU192 is unmeasured on any valid
  base. Real durability evidence now exists but came from crashes, not a test
  (see FINISHED). The lwext4 durability report is settled: it was a stale-base
  artifact, the real lwext4 is fine, and the only genuine upstream item (an OOB
  read) is filed as gkostka/lwext4#100. **Re-checked 2026-09-09: still open, still
  0 comments, `updated_at` unchanged at 2026-07-14. Nothing has moved and nothing
  is expected to; that upstream's last push was 2024-03-22.**

### VOID DATA (do not cite these again)

1. **"aarch64 crashes at VU128" is VOID.** It was the dlopen/ELF fault, which
   reproduces at **1 connection** (5 sequential calls, 2 s apart -> 5/5 fail). It
   was never a concurrency ceiling.
2. **"~2190 tps aarch64" is VOID** as a comparable figure: it used a tiny in-cache
   dataset.
3. **Pre-2026-09-07 x86 benchmark numbers have unrecoverable provenance.** The
   branches they were measured on pin `apps` at 57c607984393, a commit that exists
   in no repository, so the application side of those runs cannot be reconstructed.
   Scope, stated precisely: this voids the PROVENANCE OF THOSE X86 RESULTS. It does
   not mean the PRs are broken. Exactly one open PR (#1458) ever carried the bad
   pin, and it is fixed as of b01994d04.
4. **"ZFS COW caps ~500-530 MB/s" is VOID**, ~9x optimistic. Measured on x86:
   ~60 MiB/s against a 107 MB/s achievable 8K-sync device ceiling. Keep BOTH arms'
   findings separate: x86 hit a device/COW amplification wall, aarch64 hit a guest
   software serialization wall (`LWLock:WALWrite` on 56 of 64 backends with the
   device 98% idle). Do not merge them into one story.
5. **"OSv does not boot under -M q35" is VOID as a framing.** It is not
   machine-type-dependent: `pc` + `ich9-ahci` + `ide-cd` hangs too. The real bug is
   that OSv's AHCI probe hangs whenever any AHCI port presents an ATAPI device.
   Fixed in #1498.
6. **The old 99,504 NOPM Linux reference is VOID as a comparator.** It was a
   16-vCPU VM with glibc, compared against OSv guests on 32-vCPU bare metal with
   musl. It understated Linux by 2.33x. The correct reference is **232,139 NOPM
   @ VU8** (32 logical = 16 physical x 2 HT on socket 0, musl, bare metal, 16 GiB
   ARC cap). **Every gap figure in this repo's docs predating 2026-09-08 was
   measured against the void baseline.**
7. **The x86 "CPU/guest-bound" verdict at VU32 is RETRACTED.** qemu used 40-50%
   of ONE core against a 3200% ceiling, i.e. ~1.6% of available guest CPU with
   the host 99.8% idle: it refutes "CPU-bound" by ~60x. The underlying error is
   worth keeping: **PostgreSQL `state='active'` means "not waiting on a
   REGISTERED wait event", NOT "on CPU".** A backend blocked in something OSv
   does not surface as a PG wait event is indistinguishable from one doing
   arithmetic. What replaces it is stronger and still open: an **unattributed
   stall** (device 12-19% util, `LWLock:WALWrite` only 1-5 of 32 backends, yet
   ~0.5 of 32 vCPU consumed).
8. **The "ZFS COW ~60 MiB/s wall" is VOID as a steady-state number.** It was
   measured during crash recovery, not normal operation.
9. **The `zfs-2.4.1-osv` version banner was invented.** No such upstream tag
   exists; do not cite it. Authoritative version = the submodule **gitlink**
   (`.gitmodules branch=` is advisory and META always agrees with the gitlink by
   construction). See `.local/deps-currency.md`.
10. **"There is no scaling region on Linux either" is VOID.** It was a 16-vCPU
    saturation artifact of the old baseline box. The geometry-matched reference
    scales cleanly to VU64 (213,505 @ VU8 -> 614,277 peak @ VU64), which is
    precisely what makes OSv's VU8 peak a shape difference worth explaining.
11. **"aarch64 connect latency ~100 ms is a standing property" is VOID as of
    2026-09-10.** It was fork page-table clone cost and is fixed: 117.3 -> 3.98 ms,
    with `n_ptes` 4,445,585 -> 132,497. Do not cite the ~100 ms figure as current.
12. **"GitHub's `mergeable` flag" is VOID as a conflict oracle for this repo.**
    GitHub does not apply `.gitattributes` merge drivers, and this repo declares
    `modules/tests/Makefile merge=union` (upstream `d7c3cb81a`), so every PR that
    adds a test line is reported CONFLICTING when it merges cleanly. The
    authoritative check is `git merge-tree --write-tree --messages
    upstream/master <branch>` **from a worktree checked out at
    `upstream/master`**; exit 0 = clean. **Trust merge-tree over GitHub.**
    Round 13 found **two** live false positives this way: **#1440** and **#1449**,
    both GitHub-CONFLICTING and both merge-tree clean, and both touching only
    `modules/tests/Makefile` beyond their own new files. Getting this backwards
    caused #1489 to be opened and retracted.
13. **"A PR's head branch is editable on GitHub" is VOID.** `PATCH
    /repos/.../pulls/N` accepts a `head` field, returns HTTP 200, and **silently
    discards it** (proven with controls). The only ways to change what a PR
    points at are force-push to the existing head branch or recreating the PR.
    This is why #1447 still carries `pr/ext4-perf` rather than `pr/ext4-perf-v2`.
14. **"The kconfig `config fork` plain-`bool` defect is an upstream defect" is
    VOID.** Master has no `config fork`, `conf_fork` or `CONF_fork` at all
    (three `git grep`s against `upstream/master`, all exit 1). The defect is
    introduced by #1455 and fixed within it.

## Phases

Each phase states its EXIT CRITERIA. Nothing is "done" without a pasted measured
result. Every code change lands as its own reviewable, G-signed, upstreamable PR.

### P0 - Upstream hygiene (fast, unblocks reviewers) [PARALLEL, no EC2 for most]
- **P0.1** Rebase #1449 (ext4 readlink/readdir heap overflow, SECURITY) onto
  current master. It is a REAL conflict: upstream merged bf16817c9, af27ba4b7,
  c08544641 to modules/libext/ext_vnops.cc after we branched. A security fix must
  not sit unmergeable. Force-push is blocked -> new branch + PR comment.
- **P0.2** #1447 (ext4 read-ahead perf) was stacked on #1431, which is NOW MERGED
  (af27ba4b7). Rebase, re-validate the perf claim, consider un-drafting.
- **P0.3** Keep every other PR mergeable and answered. Currently no reviewer is
  waiting (we are last commenter everywhere); #1464 is APPROVED awaiting merge.
- EXIT: #1449 + #1447 mergeable and re-validated; 0 PRs with an unanswered
  reviewer comment.

### P0.4 - Rebase the fix stack onto current upstream/master [GATES P1/P3/P4/P5]

STATUS CORRECTION 2026-09-05 (second look): the framing below overstated the
work. Measured: v26 is 129 commits ahead of master and 24 behind, but those 129
are NOT orphaned work - they are the integration branch, and essentially all of
them are ALREADY REPRESENTED in ~20 open PRs (pr/numa-harden,
pr/nvme-int-coalescing, pr/condvar-wake-lock, pr/openzfs-runtime-datapool,
pr/sched-idle-pull, pr/virtio-net-multiqueue, the #1455/#1456 fork trilogy, etc).
Patches 0030/0031/0032 are already forward-ported on #1487. So there is NO large
body of unmerged work needing a 129-commit replay.

What P0.4 actually is, then:
- NOT a heroic rebase. The individual PRs are each already based on, or trivially
  rebasable onto, master (15 PR heads are behind=0 today).
- The v26/aarch64 BENCH branches are stale, and that is what matters: any
  benchmark measured on them is confounded (proven twice: the ext_fsync/lwext4
  phantom bug, and the ae077860c virtio-blk stall contaminating every p99 number).
- So the real requirement is narrower: build the NEXT benchmark base from
  upstream/master plus only what is genuinely needed (master + #1488 + #1487's two
  ARC commits + the fork stack as it stands in its PRs), and measure on THAT.
  Do not resurrect v26.

Revised exit criteria: a fresh benchmark base derived from current master that
builds, boots, serves PostgreSQL on ZFS, and contains ae077860c; the p99 and
aarch64 sweeps re-run on it; v26 retired as a historical artifact rather than
rebased.

BLOCKER FOUND 2026-09-05 (see .local/CLEAN-BASE-PROBLEM.md): master has every fix
we need (ae077860c, af27ba4b7, the OpenZFS keystone) but has NO fork() at all -
no libc/process/fork.cc, no conf_fork. PostgreSQL requires fork, so the base must
be master + the fork stack. #1455 merges clean onto master (exit 0) and brings
fork.cc, but #1456 does NOT stack on it: 10 conflicted files, with add/add on
libc/process/fork.cc, arch/*/fork.cc and include/osv/fork.hh. That add/add pattern
means #1456 is a REVISED VERSION of #1455's work, not an increment - they are
alternative presentations of the same feature and cannot be composed by merging.
How they should compose is a maintainer question, not a mechanical rebase.

Path forward, in order of preference:
(a) master + #1455 alone. It contains ae077860c so the p99 stall is gone. Verify
    PostgreSQL actually runs there (fork without the per-child COW address space)
    before committing to it.
(b) If PG needs #1456's per-child COW for multi-backend load: merge current master
    INTO v26 (not a rebase) to pull in ae077860c + af27ba4b7, accept the messier
    history, and label the base precisely.
(c) Wait for the maintainer on #1455/#1456 - blocks indefinitely, not acceptable.
Discovered 2026-09-05 and it already produced one WRONG conclusion, so this is
now a hard gate before further benchmarking.

Our fix-stack branches (wip/pg-zfs-bench-v26, wip/aarch64-forkcow-signed) are
**24 commits behind upstream/master**, and the missing set includes our OWN
merged PRs plus code on paths our results depend on: 0e34e4dc2 (the OpenZFS
keystone itself -- our branch carries an older private copy), a4d3abd8e (mm:
mremap, +191 lines in core/mmu.cc), 70446eb44 (elf ld-musl soname), a92c44f9b
(numa SRAT/SLIT), a5ed68053 (virtio-net RX mbuf refcount), af27ba4b7 (libext
real fsync + page-cache bridge), 6c9d0489b, 9450d690d, 95f478cb7, 07f61154a,
bf16817c9, b7a652efa, d7c3cb81a.

What it already cost us: on that stale base `ext_fsync` is `vop_nullop`, so
fsync(2) on ext4 is a NO-OP. That is why PostgreSQL appeared to "lose newly
created files" on ext4 -- we concluded lwext4 was broken and drafted an upstream
bug report. A C reproducer against the real lwext4 fork tip PASSES every case
(clean unmount, post-fsync crash, 200-file create): lwext4 is fine. The bug was
OUR STALE BASE. Reproducer kept at .local/lwext4-repro/; the draft report is
marked DO-NOT-FILE.

- Impact triage: the PG-on-ZFS results STAND (af27ba4b7 is ext4-only; the ZFS
  path is untouched). The ext4 arm conclusions are INVALID and must be re-run.
- Do: rebase the stack onto current upstream/master, expecting the main conflict
  where our private copy of the OpenZFS keystone meets the merged 0e34e4dc2.
  Re-validate (build + boot + a PG-on-ZFS smoke run) before any new benchmark.
- STANDING RULE this creates: before concluding "X is broken", verify the base
  contains the relevant upstream fix. Stale-base bugs masquerade as real ones.
- EXIT: fix stack rebased onto current master, builds, boots, serves PG on ZFS;
  ext4 arm re-tested on the fresh base; benchmarking resumes from there.

### P0.5 - Extract buried generic fixes + the build-system gap [small, high value]
Two concrete items found 2026-09-05, both independent of the rebase:

1. **Makefile bootfs_dep gap.** `bootfs_dep` (top-level Makefile, just above
   `$(out)/bootfs.bin`) adds the ZFS userspace set only under `ifeq ($(fs),zfs)`,
   so `fs=ramfs` gets neither `$(tools)` nor the openzfs `.so` set, while
   `modules/zfs-tools/usr.manifest` still names `libzfs_core.so` etc, so
   `mkbootfs.py` dies. It should key on `conf_zfs=openzfs`, not `fs=zfs`. THIS IS
   the gap behind the "pre-build the .so set first" workaround carried in every
   build brief for months. Related trap to document or fix: two `$(out)/zpool.so`
   rules exist (openzfs and legacy bsd/cddl), and pre-building without
   `conf_zfs=openzfs` silently yields the legacy binary, which fails at runtime
   with `failed looking up symbol zpool_set_history_str`.
2. **Audit the fork mega-commits for buried generic fixes.** #1492 (RDRAND early
   read) sat unshipped inside `858dd78f2` for weeks purely because it was swept
   into a large feature commit; its own comment even says "independent of fork".
   Each buried fix is value already paid for but not delivered. Grep the big
   commits for self-contained non-fork hunks and extract them as their own PRs.

3. **Add `conf_fork=0` to the standing build checks (PROPOSED 2026-09-09, not
   installed).** The gap: the fork branches have only ever been built with
   `conf_fork=1`, so a `#if CONF_fork` asymmetry compiles for us and breaks for
   anyone building the default config. That is what bit
   `include/osv/elf.hh`.

   **Measured cost of the full-build approach, and why it is NOT as cheap as
   hoped.** `make build/release.x64/core/elf.o conf_fork=0` in a fresh worktree
   needs, in order: `kbuild` + `musl_1.2.1` submodules (3 s), `external/x64/acpica`
   (7 s, and its relative `.gitmodules` URL resolves against `origin`, so it must
   be cloned from the GitHub URL explicitly), a `boost_base=` pointing at a store
   path containing `libboost_system*.a`, and then **kconfig, which needs ncurses
   and fails without it** (`kconfig/mconf-libs` Error 1). So the honest cost is a
   toolchain prerequisite, not "seconds", and it would need something installed.

   **Cheaper alternative that catches the same defect class, proposed as
   `scripts/check-conf-fork0.sh`:** preprocess the guarded headers under both
   `-DCONF_fork=1` and `-DCONF_fork=0` and assert that every surviving
   `virtual ... override` still has a surviving base declaration. No submodules,
   no kconfig, no ncurses, no image, no boot; runs in about a second with nothing
   installed.

   **Validated both ways rather than assumed.** Against the real pre-fix header
   (`da3041f5d`): passes at `CONF_fork=1`, **FAILS at `CONF_fork=0`**. Against the
   fixed header (`ff7fba040`): passes at both. Cross-checked against a real `g++`,
   which agrees exactly (base-inside-guard + override-outside: compiles at
   `CONF_fork=1`, compile error at `0`; both-inside-guard: compiles at both). So
   the check would have caught the actual bug and does not fire on the fix.

   Deliberately scoped: it is a shape check on preprocessed headers, not a
   substitute for a real `conf_fork=0` kernel build. **Nothing was installed and
   the script was not committed** pending a decision on where it belongs.

### P1 - p99 / latency-consistency pass (the top performance gap) [EC2]

STATUS 2026-09-05: ATTEMPTED, and the answer is BLOCKED ON P0.4. The measured
tail at VU32 is NOT driven by any PostgreSQL knob: it is an OSv virtio-blk
completion-path stall (19.3 s observed; 1 backend in IO|WalSync with 21 convoyed
behind LWLock|WALWrite, while PG's own accounting showed write=153.384s but
sync=0.033s, proving the stall is below PG). Upstream ae077860c already fixes it
("virtio-blk: do not hold the per-queue lock while draining completions"); our
v26 carries 1e3d84143 (multiqueue, which introduced the deadlock) WITHOUT the
cure. So p99 on this base is confounded and no PG-knob conclusion is valid.
Re-run after the rebase. See .local/STALENESS-PATTERN.md.
Everything so far optimized NOPM. p99 was measured, never tuned.
- Sweep, at a FIXED moderate VU (near vCPU count) on bare metal:
  checkpoint_completion_target, bgwriter_lru_maxpages/delay, wal_writer_delay,
  wal_buffers, and ZFS recordsize interaction. Then re-check at VU>vCPU.
- Report p50/p95/p99/p99.9 per config, not just NOPM. Identify which knob
  actually moves the tail and whether any OSv-side lever (wake locality,
  checkpoint I/O smoothing) is implicated.
- EXIT: a documented latency-optimized profile with measured p99 improvement at
  equal-or-better NOPM, added to PG-ON-OSV-TUNING.md; any OSv-side finding PR'd.

### P2 - aarch64 unblock + benchmark (second ISA to parity) [EC2, Graviton]
- **P2.1** Fix the >=4 GB `setup_temporary_phys_map` coverage bug (generic OSv
  aarch64 kernel fix, upstreamable on its own).
- **P2.2** Re-sign/split wip/aarch64-forkcow-signed into reviewable PRs (build
  ports; split-TTBR fork-COW; timer-park) once #1455 lands or as a stacked series.
- **P2.3** VU-sweep Graviton3 with a realistic guest; produce the
  aarch64-vs-x86_64 table.
- EXIT: aarch64 runs a full VU sweep at >=8 GB guest; comparison table published;
  the map fix is its own PR.

### P3 - Remaining knob sweep (efficiency, lower risk) [EC2]
From PG-ON-OSV-TUNING.md sec 11: OSV_IDLE_SPIN sweep; NVMe interrupt coalescing
on a vwc=1 device; hugepages for a read-heavy/big-shared_buffers config; NUMA
locality on a 2-socket metal host; vCPU pinning/topology; Firecracker vCPU
pinning + MMIO queue depth.
- EXIT: each knob has a measured verdict (helps / null / hurts, with numbers) and
  the tuning doc records it. Anything that helps generically -> PR.

### P4 - M2: PGXN extension coverage [EC2]
Verify representative PGXN extensions build and work identically on OSv vs Linux
(dlopen-heavy path, which historically stressed fork/COW). Start with widely used
ones (pg_stat_statements, pgvector, postgis if feasible), then broaden.
- EXIT: a matrix of extensions x (OSv, Linux) with pass/fail and any OSv fix PR'd.

### P5 - Durability + resilience at scale [EC2]
- Crash-consistency: kill -9 / power-cut the guest under load, verify ZFS + PG
  recover cleanly every time (this is the real production question).
- The extreme-scale throughput cliff (fragmentation past VU192) if a workload
  needs it: page-allocator anti-fragmentation, aimed by the v26 OOM diagnostic.
- lwext4 durability bug: file upstream once a self-contained C reproducer exists.
- EXIT: documented crash-recovery guarantee; fragmentation lever measured or
  explicitly deferred with rationale.

## Standing engineering rules (non-negotiable)

1. Measurement-first. Source reading yields hypotheses; only build+measure
   confirms. No "works"/"faster"/"fixed" without a pasted number or log.
2. Generic, not PG-specific. Fixes go in mmu/sched/mm/elf/libc/fork/drivers or as
   an open_zfs patch, never as a PG special case.
3. One reviewable PR per fix, off current upstream/master, G-signed, leak-scanned
   (no em-dashes, no AWS IDs/account numbers/IPs).
4. Never force-push; push to a new branch. Never `git add -A`. Never touch the
   tracked .gitignore. Never `rm -rf`.
5. Substrate invariants: bare metal only (needs /dev/kvm); ZFS pool =
   `ashift=12` on a DEFAULT 512-logical raw virtio disk (a 4K-logical override
   breaks pool create); clone URL is github.com/gburd/osv-1 (WITH the -1).
6. Clean up EC2 (terminate + verify 0 orphans) and local scratch every time.
7. **A retraction must land in THREE places, verified separately:** the **PR
   body**, the **commit message**, and the **code**. They fail independently. A
   body is editable forever; a commit message is what gets merged into `git log`
   permanently, so a correction that lands only in the body **does not survive the
   merge** and the wrong version is the durable one. Found 2026-09-09 on #1476
   (fixed via #1501) and #1447 (disclosed, deferred to its re-measurement). The
   round-10 harness compared thread against *code* and could not see this.
8. **A PR's `head` is NOT editable on GitHub.** `PATCH /pulls/{n}` accepts a
   `head` field, returns 200, and silently discards it. So **"retarget the head"
   is never a valid recommendation**; the only options are a force-push over the
   existing head branch or **recreating the PR**. Verified with controls (a
   nonexistent branch is accepted and ignored identically; `base` on the same call
   works). Recreating is cheap when the review surface is empty, and there is
   precedent: #1439 is a recreation of #1421, and #1501 of #1476. **Measure the
   review surface first** and cross-reference both directions in the same pass.
9. **Exercise `conf_fork=0`, not just `conf_fork=1`.** A conditional-compilation
   break in a config nobody builds is invisible to review, merge-tree, the leak
   scan and CI.
10. **`state='active'` is not "on CPU".** Before concluding a workload is
    CPU-bound from PostgreSQL wait events, check a host-side counter. This error
    cost a published verdict (void-data item 7).
11. **Watch for the recurring defect shape:** an artifact that is internally
    self-consistent and wrong only against something nobody checks. Five
    instances now: #1497's table (wrong against the resolver until executed); the
    unlanded correction (thread vs head); the `conf_fork=0` break (wrong in the
    config nobody builds); the retracted claim surviving in a commit message
    (wrong in the artifact that outlives the review); and the void Linux baseline
    (self-consistent, wrong against a matched comparison). The lesson each time:
    **execute or compile the thing, do not read it**, and prove the check would
    fail if the bug were present.

## P0.4 execution detail (from the maint-4 staleness audit)

Both benchmark branches are 24 behind (22 non-merge). Per-branch: v26 = 24
behind / 129 ahead / 21 dry-run conflicts; aarch64-forkcow-signed = 24 / 133 /
22 (plus modules/zfs-tools/usr.manifest modify-delete -> take the delete).
15 PR head branches are already behind=0.

### THE DANGEROUS CLASS IS SILENT
core/mmu.cc, core/sched.cc and core/elf.cc AUTO-MERGE with NO textual conflict
on both branches, even though both sides make large edits (ours: +1187 mmu,
+607 sched, +144 elf; upstream: a4d3abd8e mremap +191 in mmu.cc, 70446eb44 in
elf.cc). Git will produce a clean tree that has never been compiled.
**A clean rebase is NOT evidence of correctness here.** mremap's new lines land
next to our rewritten vma_list / COW fault path with no review prompt.

### The OpenZFS keystone collision (the tall pole)
v26 predates the #1423 restructure: v26 expresses ZFS work as a 32-patch series
over a `patches/` layout; upstream 0e34e4dc2 RELOCATED the real source to
modules/open_zfs/osv/ (124 tracked files) and shrank patches to 1. So v26's ZFS
work lives in a layout that no longer exists -> this is a PORT, not a merge.
MITIGATION (better than feared): patches 0030 (fork ARC waiter), 0031 (half-RAM
cap) and 0032 (sync shrinker) are ALREADY forward-ported to the new layout on
pr/zfs-arc-halfram-cap (#1487: 2e6daeb86 + ec5c557a9, sitting on 0e34e4dc2).
Cherry-pick those from #1487, do NOT re-port from v26.

### Recommended order (do NOT rebase v26 in place)
0. Create wip/pg-zfs-bench-v27 off upstream/master and MOVE work onto it.
1. #1488 (OpenZFS 2.4.4) first - behind=0, validated, establishes the pin.
2. Rebuild the ZFS layer on v27 = master + #1488 + cherry-pick #1487's two
   commits. Then audit v26's remaining 29 patches against modules/open_zfs/osv/:
   most of 0001-0029 are already upstream inside 0e34e4dc2 (it merged our #1423).
   Deliverable: the diff-list of v26 patches with no upstream equivalent.
3. Replay the fork/mmu/sched stack in dependency order (#1455 -> #1456 ->
   coherence fixes). Per-file discipline:
   - libc/signal.cc: the ONE guaranteed textual conflict (vs 6c9d0489b POSIX
     default-ignore for SIGCHLD/SIGURG/SIGWINCH). We route SIGURG for the
     per-backend latch. Resolve SEMANTICALLY, do not take a side wholesale.
   - core/mmu.cc / core/sched.cc / core/elf.cc: FORCE review of the silent
     auto-merge; specifically diff mremap_src/inspect_mremap_src against our COW
     fault path and confirm mremap's locking holds under per-child address spaces.
   - DROP our 2c30f7570 (virtio-net RX refcount): byte-identical to upstream
     a5ed68053, already merged.
   - drivers/virtio-blk.cc: reconcile our private drain fix (99191d1b9) against
     upstream ae077860c - PREFER UPSTREAM, keep ours only if it fixes something
     upstream's does not, and document which.
4. aarch64 branch LAST (shares the stack + arch/aarch64). P2's
   setup_temporary_phys_map fix should be authored ON THE FRESH BASE so it is
   upstreamable standalone.
5. PR heads: 15 already current; the numa trio (#1438/#1441/#1445) needs a real
   forward-port onto master's core/numa.cc (add/add); #1442/#1444 merge clean,
   rebase when #1442 moves.

### Re-validate after (nothing is trusted across this rebase)
1. Boot + zpool create/scrub/mount on the new ZFS layer, BEFORE any benchmark.
2. fork/COW correctness (all three M1 coherence root causes) - mandatory because
   mmu.cc auto-merged with mremap.
3. Re-run the VU sweep (expect ~248k @ VU32 with OSV_WAKE_PULL). Old v26 numbers
   are NOT comparable to post-rebase numbers.
4. Re-confirm crash-free VU192 (autovac off) / VU128 (on) - the reclaimer moved.
5. ext4-on-arm PG retest with a REAL ext_fsync (closes the lwext4 correction).
6. Signal handling under fork (SIGURG latch, SIGCHLD reaping) after the
   6c9d0489b reconciliation.

### Standing method rules this audit produced
- To test whether a PR conflicts: dry-run `git merge-tree` from a worktree
  CHECKED OUT AT upstream/master so .gitattributes merge drivers are active.
  Trust merge-tree over GitHub's cached mergeable flag.
- Before concluding "X is broken", verify the base contains the relevant upstream
  fix. Stale-base bugs masquerade as real ones (cost us the lwext4 false alarm).
- Never hand-port hunks git can merge itself - especially security fixes.

---

## M1 PARITY STATUS (2026-09-13): NOT MET, but now HONESTLY MEASURED and the gap is NAMED

First fully-matched, one-variable OSv-vs-Linux benchmark (same m5d.metal, same NVMe, Linux in a matched
KVM guest, 32 GiB ARC binding on both, PG 18.6 musl both, all OSv levers on, WAKE_PULL default-on):

    VU    OSv       Linux     ratio
     8    104,640   159,792   0.655
    16     64,839   268,921   0.241
    32    (deadlock; #1502 clears it -> ~62,400, still far below Linux)

OSv declines VU8->VU16 (-38%); Linux scales (+68%). Parity NOT met; gap WIDENS with concurrency.

**Why the number moved in BOTH directions vs the old 4.9x:** the old baseline (16-vCPU VM/glibc) was
handicapped. Matched, VU8 is only 0.655x (better than believed) but VU16 is 0.241x (worse - because
Linux SCALES and OSv does not). The methodology fix delivered an honest number, not a flattering one.

**The single remaining throughput ceiling is NAMED: OSv WAL-commit-completion serialization.** At VU16
OSv NULL-wait jumps to 68% (device 28%, 12/32 vCPU busy) while Linux stays WALWrite-bound and scales.
Backends block waiting to be WOKEN after their commit completes. WAKE_PULL does not help (nothing
runnable to steal). This is the next G2 target; the iowake syncwrite isolate is the cheap A/B instrument.

**Wins banked from this run:** #1502 proven end-to-end (clears the VU32 deadlock on a real workload, not
just the assertion); the projected-merged-base + gate methodology now enforced; a general physio()
multi-iov fix split out as #1508.

**Remaining M1 work, reprioritized:** the WAL-commit-completion wakeup path is now THE lever. Everything
else (fsync scan, wake-placement, lock-order) is fixed or filed. Win M1 there or characterize why not.
