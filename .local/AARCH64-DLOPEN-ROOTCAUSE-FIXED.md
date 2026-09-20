# ROOT CAUSE FOUND AND FIXED: the ELF object cache is AS-blind while PT_LOAD mappings are per-AS

2026-09-08, agent 01a081c8 on c7gd.metal (box terminated, 0 orphans). **One bug, both ISAs.**
This is the aarch64 `plpgsql` blocker AND, per the x86 arm's independent confirmation, the
x86 `dlsym` fault. Two blockers collapse into one fix.

Identity: OSv `9533cf94` (`wip/aarch64-forkcow-signed` tip), apps `b38b99cd`.
**Note: `eb164dcd` does not exist in `gburd/osv-1.git`** and neither `ae077860c` nor
`746e5bcd` is an ancestor of that branch. The briefed base was a local-only SHA; I built the
branch tip. Fix branch: `gh-fork/fix/elf-object-cache-address-space` (2 commits, both `%G?`=G).
Reported on PR #1456 (comment 5589623221), NOT as a master PR (master has no fork()).

## The invariant violated, in one line

`elf::program`'s object cache (`_files`) and module list are **process-global**, but an
object's PT_LOAD segments are mapped into whichever **address space** was current when it was
first loaded (`file::load_segment` -> `mmu::map_file` -> `cur_vma_list()`).

`program_base = 0x100000000000` is app PML4 slot 32; `clone_address_space` deep-copies slots
1..127 per child. So each child has a private `vma_list` and page-table subtree for exactly
the region shared objects live in, while the map handing out `_base` is global. They disagree
by construction.

`program::load_object`'s cache hit (`core/elf.cc:1626`) contains **zero** references to any
address space. That is the bug.

## Why every competing theory died

**12 concurrent and 5 sequential backends faulted at the IDENTICAL address.** That is because
`_base` is frozen at first load, so every later consumer is a cache hit on the same object. A
fresh per-backend dlopen would advance `_next_alloc` and give a different address each time.
This single datum kills the race, the alignment-gap and the ARC-reclaim theories.

## "outside application" means NO VMA, provably

`vm_fault` aligns down BEFORE the vma lookup and `vm_sigsegv` prints the aligned value, so a
page-aligned address implies the slow path. `fast_sigsegv_check` is `return false;` on
aarch64, and `ESR=0x96000007` has bit 6 clear = a READ, so `access_fault()` (`!(perm &
perm_read)`) cannot be true for a readable segment. Both alternate routes are excluded: it is
literally `find_intersecting_vma_in(*as->vmas, addr) == end()`.

Instrumented at that exact branch:

    === round 0: fork
    OSVDIAG loadseg /libplug.so base=0x100000050000 va=[0x10000008f000,...) as=0x6000ffe35580 as0=0
    [child0] RESULT plug_answer()=42          <- works in the AS that mapped it
    === round 1: fork
    OSVDIAG cachehit /libplug.so base=0x100000050000 as=0x600041116300 as0=0   <- maps NOTHING
    OSVDIAG novma addr=0x000010000008f000 as=0x600041116300 as0=0 err=0x96000007
    OSVDIAG  NOT-in-AS0 either
    page fault outside application, addr: 0x000010000008f000
    PC: <elf::object::dynamic_tag(unsigned int)+8>   X00: 0x000010000008fdf0

## MY "SILENT CORRUPTION" UPGRADE WAS WRONG (self-refuted by probe)

I speculated that because round 0's child AS is destroyed and its pages freed, a later child
could hold a LIVE mapping at that VA and the cache hit would hand out a pointer into another
process's memory. **I built an `alias` probe to test it and it refuted me:**

    [loader] libplug plug_answer at 0x100000060168     (library at 0x1000000xxxxx)
    [mapper] mmap[0] = 0x200000201000 ... mmap[7] = 0x200000271000

`find_hole` starts at `0x200000000000` (`core/mmu.cc:2113`), nowhere near the program region,
and `_next_alloc` is process-global so two libraries never collide. **No live mapping reuses
the freed VA: it is a clean fatal fault, not silent corruption.** Recorded because the
operator explicitly asked, and because a plausible-sounding escalation that the evidence
denies is worth more as a refutation than as a caveat.

## Reproduced with NO PostgreSQL, in 60 lines of C

`fork()` + `dlopen()` + `dlsym()` of a tiny .so. Child 0 works; child 1 faults at the
identical PC/address. No PG, no ZFS, no HammerDB, no concurrency. Committed as
`tests/tst-fork-dlopen-as.cc` + `tests/libdlopenas.cc`.

Register signature from the committed test: X07/X12/X13 spell `ibdlopen`/`s/libdlo`/`penas.so`
- structurally identical to production's `/plpgsql`/`r/lib/pl`/`pgsql.so`.

## The fix, and the two traps in it

On a cache hit, if the object is not mapped in the CALLING address space, re-establish it
there at its existing base. Mapping alone is NOT enough (each cost one build to learn):

1. A writable segment is `MAP_PRIVATE` from file, so it returns **unrelocated** (zero GOT).
   Symptom: fault at address **0** right after a SUCCESSFUL dlsym. Must re-run `relocate()`,
   then `fix_permissions()`, then constructors.
2. `load_segment`'s fork-shared range registration must become **one-shot**: a remap covers
   already-registered VAs, and the vector's realloc/free lands on the CALLING AS's fork arena.
   Symptom: `fork_arena.cc: recover: h->magic == chunk_magic`.
3. Objects with no backing file (the kernel `memory_image`) must be excluded, or boot dies at
   `cannot load from Elf memory image`.

Memory cost, stated: RO/exec segments cost nothing extra (same file offsets, same pages);
writable segments become a private per-AS copy, which is correct for a forked process and is
what a normal dlopen there would have cost. A few pages per PG backend.

## Honesty gate: both artifacts on the same setup

PRE-FIX (committed test, fix disabled via `if (false && ...)`, same image otherwise):

    PASS: round 0: child dlopen + dlsym + call (status 0)
    page fault outside application, addr: 0x00001000000ef000
    PC: <elf::object::dynamic_tag(unsigned int)+8>

POST-FIX (clean committed code, instrumentation removed, rebuilt):

    PASS: round 0..11: child dlopen + dlsym + call (status 0)
    PASS: parent (the address space that did not load it) dlopen + dlsym + call
    tst-fork-dlopen-as: 0 failures      QEMU_EXIT=0

Both fault DIRECTIONS covered and verified: later-forked-child as second consumer (the PG
shape) AND **AS0 itself** as second consumer (the x86 arm's `parent` variant, which a
fork-child-only fix would have missed).

## Not tested: the fix on x86_64

The fix compiles for x64 but I did not RUN it there (this box is aarch64; the x86 cross build
needs a toolchain this box lacks). The x86_64 *bug* is independently confirmed by the other
arm. Stated in the #1456 comment rather than implied away.

## Substrate notes for the next agent

- `-kernel loader.img` (not `.elf`); fedora:39 container qemu **8.1.3** (host qemu 11 cannot
  boot OSv); root disk is **qcow2**.
- The image's baked cmdline was NOT used by `-kernel`; pass `-append "/app args"` explicitly
  or you get `Failed to load object: tests/tst-hello.so`.
- Build container needs `libstdc++-static` + `boost-static` (else `libstdc++.a needs to be
  installed`) and `python3-setuptools` (else `modules/tests/module.py` dies on
  `No module named 'distutils'` - pre-existing breakage, unrelated to this fix).
- `apps/postgres18-musl` needs `musl-gcc`, absent from the plain fedora:39 image
  (`configure: C compiler cannot create executables`). The minimal reproducer avoided needing
  PG at all, which is what made this cheap.
