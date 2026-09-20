# ROOT CAUSE: elf::program's object cache is process-global, PT_LOAD mappings are per-AS

2026-09-08, agent 541f3862 on c7gd.metal (box i-0ad3bc4a8f44d3e50). **Proven, with a 60-line
C reproducer and no PostgreSQL.** This supersedes every earlier theory for both the aarch64
and (pending confirmation) the x86 benchmark blocker.

## The mechanism

`elf::program`'s `_files` / `_modules` link map is **process-GLOBAL**. PT_LOAD segment
mappings are **PER-ADDRESS-SPACE** (`map_file` records into whichever AS is current). So:

1. child A forks, `dlopen("/lib.so")` -> segments mapped into **child A's** AS,
   `_files["/lib.so"]` caches the object with `_base` = some VA;
2. child B forks later with a **different** AS, `dlopen`s the same path;
3. `core/elf.cc:~1626` returns the **cached** object and **maps nothing**;
4. `_dynamic_table = _base + PT_DYNAMIC.p_vaddr` points at a VA mapped in **no** AS;
5. `find_intersecting_vma_in(as->vmas, addr) == end()` -> page-aligned
   "page fault outside application" inside `dynamic_tag()`.

Instrumented output from the reproducer, which makes it unarguable:

    === round 0: fork   (child AS 0x6000412ca800)
    OSVDIAG loadseg /libplug.so base=0x100000050000 va=[...,0x100000091000) as=0x6000412ca800
    [child0] RESULT plug_answer()=42            <- WORKS
    === round 1: fork   (child AS 0x6000412ca880, a DIFFERENT AS)
    OSVDIAG cachehit /libplug.so base=0x100000050000 as=0x6000412ca880   <- maps NOTHING
    OSVDIAG novma addr=0x000010000008f000 as=0x6000412ca880 err=0x96000007
    OSVDIAG  prev [0x100000040000,0x100000041000)   NOT-in-AS0 either
    page fault outside application, addr: 0x000010000008f000
    PC: <elf::object::dynamic_tag(unsigned int)+8>

## Verified independently by me
- The cache-hit path at `core/elf.cc:~1626` (`if (_files.count(name)) { auto obj =
  _files[name].lock(); if (obj) return obj; }`) contains **zero** references to any address
  space. **The cache hit is AS-blind. That is the bug in one line.**
- `vma_list` is per-`address_space` (`core/mmu.cc:141-142`).
- `program_base = 0x100000000000` is **PML4 slot 32**, and `core/mmu.cc:156` states "Only
  slots 1..127 are cloned per child". So app mappings are per-child while the cache handing
  out `_base` is global. **The two disagree by construction.**

## It explains the datum that killed every other theory
**The fault address is frozen at FIRST load, so every later backend is a cache hit.** That is
why 12 concurrent AND 5 sequential backends faulted at the *identical* address, and why the
x86 arm saw a byte-identical address across 5 occurrences on fresh boots. A genuinely fresh
dlopen per backend would advance `_next_alloc` and fault at a different address each time;
reclaim would not produce a fixed address across boots at all. Under my refuted mechanism this
datum was unexplained; under this one it is positive evidence.

It also explains why the x86 negative reproducers passed: `dlrace` (582M dlsym / 5.6M
dlopen-dlclose) and `dlrace2` (640 forks) both exercised dl concurrency, but the fault requires
**a cache hit from a DIFFERENT AS than the one that mapped the segments** - a second fork child
dlopening a library a first child already loaded. And the apparent ARC-pressure trigger was
incidental to *which* backend loaded plpgsql first, not causal (`IS_ZFS()` is false under
`conf_zfs=openzfs`, so the ARC read cache was never populated).

## Possible upgrade from crash to corruption, pending the agent's full report
The agent began "WORSE THAN A MISSING MAPPING: round 0's child AS is DESTROYED when that child
[exits]". If a later child can hold a **live, different** mapping at that same VA, the AS-blind
cache hit would hand out a pointer into another process's memory: **silent corruption instead
of a clean SIGSEGV.** Asked for that evidence explicitly, because it changes the severity and
the upstream description.

## Disposition
Needs `conf_fork=1`, and `upstream/master` has **no `fork()` at all**, so this **cannot** be a
standalone master PR. Decided:
1. Post the finding as a comment on **#1456** (`wip/fork-stage2-pr`, which carries `fork.cc`
   and the AS machinery) - a genuine defect in the *proposed* fork design, where a reviewer can
   act on it. Include the 60-line reproducer, the instrumented output, and the one-line
   invariant violated.
2. Implement/validate the fix on the fork branch, push to a NEW `gh-fork` branch, reference it
   from the comment. Reviewable without pretending it is master-eligible.
3. State that it reproduces **without PostgreSQL**, and on both ISAs if x86 confirms - a fork
   defect breaking any fork+dlopen program is far more compelling than a PG-specific one.

Fix options to weigh (agent's choice, must justify): make the `_files`/`_modules` cache
AS-aware; have `clone_address_space` also clone loaded-object segment mappings for the slots it
copies; or refuse/invalidate the cache hit when the recorded AS is not current. They differ in
whether children share or duplicate library text - **the duplicating option must state its
per-backend memory cost.**

## Process note
This is the third mechanism proposed for this fault. The first two (unlocked `_needed` vector
race; ARC/pagecache reclaim) were **both mine and both refuted by measurement or source
reading**. What finally worked was the discipline of reproducing the mechanism in isolation:
the 60-line fork+dlopen program has no PostgreSQL, no ZFS, no HammerDB, and no load generator,
and it fails in under a second.

## CONFIRMED ON x86_64 TOO (agent 0261152a) - one bug, both ISAs

The x86 agent ran the same minimal fork+dlopen reproducer on x86_64 and confirmed it, with
controls:

    child0 (the AS that mapped it):     VMA-in-this-AS = YES  -> dlopen+dlsym works
    child1 (a later, different AS):     VMA-in-this-AS = NO   -> faults in dynamic_tag
    same _base / PT_DYNAMIC (0x10000002edd8) in BOTH children

**The frozen-address prediction held exactly**: `_base` is identical across both children,
which is why every occurrence on both ISAs faulted at a byte-identical address.

Controls it ran unprompted, which is what makes this airtight:
- **negative control**: identical state but no `dlsym` -> **no fault**. Isolates the fault to
  the `dlsym` deref rather than to `dlopen` itself.
- it then went on to test whether `fork` is required at all.

## Consequences

1. **The two benchmark blockers are ONE bug.** The x86 "ELF page reclaimed under dlsym" and the
   aarch64 "vm_fault cannot populate" are the same AS-blind cache hit. Two blockers collapse
   into one fix, and the aarch64 agent owns it.
2. **Every mechanism I proposed for this fault was wrong** - three of them: the unlocked
   `_needed` vector race, ARC/pagecache reclaim, and (implicitly) an aarch64-specific alignment
   or populate defect. Refuted respectively by 582M negative samples, by source reading showing
   reclaim never removes a VMA plus `IS_ZFS()` being false under `conf_zfs=openzfs`, and by the
   byte-exact arithmetic that turned out to be a tautology.
3. **The winning method was the same each time it worked**: reproduce the mechanism in
   isolation. 60 lines of C, no PostgreSQL, no ZFS, no HammerDB, no load generator, fails in
   under a second, on both ISAs. Every hour spent on bare-metal HammerDB sweeps produced less
   diagnostic value than that one program.
4. **It is a defect in the PROPOSED fork design, not in existing OSv.** `upstream/master` has no
   `fork()`, so it cannot be a standalone master PR; it goes on #1456 with the fix on the fork
   branch.

## x86_64 confirmation details (agent 0261152a, box terminated, 0 orphans)

Reproduced **under a second** after boot, no PostgreSQL, no ZFS, no ARC, no HammerDB.
Base: osv `73a332f26`, apps `b38b99cd`.

    xas/child0-after-dlopen: base=0x10000002a000 PT_DYNAMIC=0x10000002edd8 VMA-in-this-AS=YES
    xas/child0: dlopen+dlsym OK in the AS that mapped it, fn_0(7)=7
    xas/child1:              base=0x10000002a000 PT_DYNAMIC=0x10000002edd8 VMA-in-this-AS=NO
    page fault outside application, addr: 0x000010000002e000
    RIP: <elf::object::dynamic_tag(unsigned int)+12>  RAX: 0x000010000002edd8

RIP and backtrace byte-identical to production; RAX is the walk cursor (`page+0xdd8` here,
`page+0xda0` in production). **BOTH variants fault**: AS0-as-second-consumer (`parent`) and a
later forked child (`childb`, the PostgreSQL shape). The fix must handle both, not only the
fork-child case.

### Controls that make it causal rather than correlated
- **probe mode**: identical state, identical `VMA-in-this-AS=NO`, but the faulting `dlsym` is
  never called -> **no fault**. Isolates the fault to the `_dynamic_table` deref.
- child0 always survives its own dlopen+dlsym+call: the library is fine, only the cross-AS
  cache hit is broken.
- **reclaim excluded STRUCTURALLY, not by argument**: `fs=rofs`, no ZFS in the image, and ROFS
  sets `vop_cache = nullptr` (`fs/rofs/rofs_vnops.cc:359`), so library pages are private
  anonymous via `map_file_page_read` and never enter any pagecache. My reclaim theory cannot
  even apply to a configuration that still reproduces the fault.

### An instrument trap worth remembering
The agent's FIRST probe used `msync()` and reported `VMA-in-this-AS=NO` even for the child that
DID have the mapping - a false negative that would have masked the whole finding. Cause,
confirmed by me at `core/mmu.cc:2984`:

    error file_vma::sync(...)  { if (!has_flags(mmap_shared)) return make_error(ENOMEM); ... }

`msync` returns ENOMEM for any non-`MAP_SHARED` mapping, including a correctly mapped private
library segment. **`mincore()` is the correct instrument**, because `mincore()` -> `ismapped()`
-> `find_intersecting_vmas()` -> `cur_vma_list()` is the same per-AS list the fault slow path
searches. Relayed to the aarch64 agent immediately, since the same trap would have invalidated
its evidence and its fix validation.

This is the second time this session that an instrument, rather than the code under test,
nearly produced a wrong conclusion (the first was reading `$?` after a pipe). Choosing an
instrument whose failure mode is understood matters as much as the measurement.

### Handoff artifacts on disk
`.local/xas-dlopen-x86/`: `FINDING-x86-confirmation.md`, reproducer `tst-fork-xas-dlopen.cc`,
and logs `xas-probe.log` / `xas-parent.log` / `xas-childb.log`. Leak-scanned clean.

### Confirmed not upstream-eligible
`upstream/master` has **zero** `CONF_fork` / `clone_address_space` references and is
single-address-space, so the bug cannot exist there. #1456 is the correct venue.

## FIXED (agent 541f3862). Branch `fix/elf-object-cache-address-space`, 2 commits.

    da3041f5d  elf: map a cached shared object into an address space that did not load it
    6265b5ce5  tests: cover using a shared object from an address space that did not load it

Fix shape: `object::mapped_in_current_address_space()` +
`object::remap_segments_in_current_address_space()` + `run_init_funcs_for_new_address_space()`,
so a cache hit from an AS that did not load the object re-maps the segments at the SAME base.
Keeps one base and one set of symbol addresses process-wide.

Honesty gate met, same setup, committed code:
    pre-fix:  PASS round 0, then `page fault outside application ... dynamic_tag+8`
    post-fix: rounds 0..11 PASS + parent PASS, 0 failures, QEMU_EXIT=0
Includes the **AS0-as-second-consumer** case, which a fork-child-only fix would have missed.
The committed test provably fails without the fix, so it is a gate rather than a smoke test.

Posted to **#1456** (issuecomment-5589623221), no master PR - correct, since master has zero
`CONF_fork`/`clone_address_space` references.

### The agent retracted its OWN escalation, which is the best thing in this report
It had begun to claim a "worse than a missing mapping" silent-corruption variant (a freed
child AS's VA being reused so the cache hands out a pointer into live memory). Instead of
arguing it, it **probed it**: `find_hole` starts at `0x200000000000` and `_next_alloc` is
global, so nothing reuses the freed VA. **It is a clean fatal fault, not corruption.**
Retracted before publishing. That is the same discipline I failed twice today.

It also corrected two of my premises: **`eb164dcd` does not exist** in `gburd/osv-1.git` (a
local-only SHA I had quoted as a validated base, and neither cherry-pick is an ancestor of that
branch), and it caught itself misreading `X86BUILD_EXIT=0` as a passing x86 build when it was
the `echo`'s status.

### Two implementation traps documented, each cost a build
- Re-mapped **writable** segments come back **unrelocated**, so a *successful* `dlsym` is
  followed by a fault at address 0 (NULL GOT entry). The remap must re-run
  `relocate`/`fix_permissions`/constructors.
- The fork-shared range registration must be **one-shot**, or `chunk_magic` aborts on the
  caller's fork arena.

### Caveat I had to add publicly (issuecomment-5589762634)
The agent told me the fix is **runtime-validated on aarch64 only** and that the x86_64 side is
mechanism confirmation, not patch validation - but the public #1456 comment did not say so. A
reviewer could reasonably have read "confirmed on both ISAs" as "validated on both". Posted the
distinction explicitly: the BUG is confirmed on both, the PATCH is validated on aarch64, and an
x86_64 boot plus the committed test is the outstanding item.

### Signing note (my error, not the agent's)
The two commits initially showed `%G?` = **U**. Cause: they were signed with
`greg@burd.me-signing-floki-202604` (`SHA256:H31vk+...`), a legitimate key of mine that was
**missing from `/tmp/gitsign/allowed_signers`**, which listed only one principal. Added it; both
commits now verify as **G**. The commits were correctly signed all along - my verification
config was incomplete, and I nearly recorded good work as unsigned.
