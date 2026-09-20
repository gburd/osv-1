## Defect: the ELF object cache is process-global while PT_LOAD mappings are per-address-space

Found while benchmarking PostgreSQL on this branch. It is a defect in the per-child address
space design rather than in pre-existing code, so I am reporting it here instead of opening a
PR against master (which has no `fork()`).

**Reproduces on both x86_64 and aarch64, with no PostgreSQL involved, in under a second after
boot.**

### The invariant that is violated

`elf::program`'s object cache (`_files`) and module list are **process-global**, but an
object's PT_LOAD segments are mapped into whichever **address space** was current when it was
first loaded: `file::load_segment` calls `mmu::map_file`, which inserts the vma into
`cur_vma_list()`, i.e. the current address space's own `vma_list`.

Under `conf_fork=1` those two disagree by construction. `program_base` (`0x100000000000`) is
application PML4 slot 32, and `clone_address_space` deep-copies slots 1..127 per child, giving
each child a private `vma_list` and private page-table subtree for exactly the region shared
objects live in.

So when an address space `dlopen()`s a library that a **different** address space loaded
earlier, `program::load_object` returns the cached object straight from `_files` and maps
nothing. The object's `_base`, `_dynamic_table` and symbol addresses all point at virtual
addresses that are unmapped in the caller. The first dereference dies:

```
page fault outside application, addr: 0x000010000008f000
PC: <elf::object::dynamic_tag(unsigned int)+8>
mmu::vm_fault -> page_fault -> elf::object::lookup_symbol_deep -> dlsym
ESR: 0x0000000096000007
```

Two properties of that message are worth spelling out, because both are diagnostic:

* The address is **page-aligned** because `vm_fault` aligns down *before* the vma lookup, and
  `vm_sigsegv` prints the aligned value. `fast_sigsegv_check` returns `false` on aarch64, and
  `ESR=0x96000007` has bit 6 clear so it is a **read**, meaning `access_fault()` cannot be
  true for a readable segment. Both alternative routes to that message are therefore excluded:
  it means literally `find_intersecting_vma_in(*as->vmas, addr) == end()`, i.e. **no vma
  covers the address in the faulting address space**.
* The address is **identical on every occurrence** because the object's `_base` is fixed at
  first load, so every later caller is a cache hit on the same object. This is why the failure
  looks deterministic rather than race-shaped, and it is the detail that rules out the
  concurrency and cache-reclaim theories we initially pursued: the first `dlopen` of a library
  succeeds and every subsequent one from another address space fails at exactly the same
  address, at one connection, with no concurrency at all.

### Measured, not inferred

Instrumenting the fault slow path itself at the `find_intersecting_vma_in(...) == end()`
branch, on aarch64:

```
=== round 0: fork
OSVDIAG loadseg /libplug.so base=0x100000050000 va=[0x100000050000,0x100000051000) as=0x6000ffe35580 as0=0
OSVDIAG loadseg /libplug.so base=0x100000050000 va=[0x10000008f000,0x100000091000) as=0x6000ffe35580 as0=0
[plug] constructor ran
[child0] RESULT plug_answer()=42 (expect 42)          <- works in the AS that mapped it
=== round 1: fork
OSVDIAG cachehit /libplug.so base=0x100000050000 as=0x600041116300 as0=0   <- maps NOTHING
OSVDIAG novma addr=0x000010000008f000 as=0x600041116300 as0=0 err=0x96000007
OSVDIAG  prev [0x100000040000,0x100000041000) perm=3 fl=0xa3
OSVDIAG  NOT-in-AS0 either
page fault outside application, addr: 0x000010000008f000
```

Same `_base` in both address spaces, mapped in the loader and absent from the cache-hit
address space, and absent from AS0 as well.

The same mechanism measured independently on **x86_64** via `mincore()` (which consults
`ismapped()` -> `find_intersecting_vmas()` -> `cur_vma_list()`, the same per-AS list the fault
path searches):

```
xas/child0-after-dlopen: base=0x10000002a000 PT_DYNAMIC=0x10000002edd8 VMA-in-this-AS=YES
xas/child0: dlopen+dlsym OK in the AS that mapped it, fn_0(7)=7
xas/child1:              base=0x10000002a000 PT_DYNAMIC=0x10000002edd8 VMA-in-this-AS=NO
page fault outside application, addr: 0x000010000002e000
RIP: <elf::object::dynamic_tag(unsigned int)+12>  RAX: 0x000010000002edd8
```

`RAX`/`X00` is `_dynamic_table`, the walk cursor in
`for (auto p = _dynamic_table; p->d_tag != DT_NULL; ++p)`.

Controls, on x86_64:

* A **probe-only** mode that reports the identical `VMA-in-this-AS=NO` state but never calls
  the faulting `dlsym` does **not** fault, isolating the fault to the `_dynamic_table`
  dereference itself.
* The first loader always survives its own `dlopen`+`dlsym`+call, so the library is fine; only
  the cross-address-space cache hit is broken.
* Page-cache reclaim is excluded structurally, not by argument: the image is `fs=rofs` with no
  ZFS, and ROFS sets `vop_cache = nullptr`, so library pages are private anonymous pages via
  `map_file_page_read` and are never in any page cache.

**Both directions fail**, so a fix must not special-case the forked child:

* a later forked child is the second consumer (the PostgreSQL backend shape), and
* **AS0 itself is the second consumer** when a forked child loaded the library first.

### Why this matters beyond PostgreSQL

Any program that forks and then `dlopen()`s the same library in more than one address space
hits this. The PostgreSQL symptom was that every `plpgsql` call faulted at one connection,
which made all six HammerDB TPROC-C stored procedures unusable on this branch;
`shared_preload_libraries=plpgsql` does not work around it, it just moves the failure earlier
into postmaster startup by loading the library pre-fork.

### Reproducer

`tests/tst-fork-dlopen-as.cc` plus `tests/libdlopenas.cc` on the branch below. It forks
repeatedly, and in each child `dlopen`s, `dlsym`s and calls into the same library, then repeats
with the parent as the second consumer. The library's function reads a writable global that a
constructor sets, so the test also catches the weaker failure where the segments are mapped but
relocations or constructors were not re-established for the new address space.

Before the fix, aarch64:

```
PASS: round 0: child dlopen + dlsym + call (status 0)
page fault outside application, addr: 0x00001000000ef000
PC: <elf::object::dynamic_tag(unsigned int)+8>
X07: 0x6e65706f6c646269  X12: 0x6f6c6462696c2f73  X13: 0x6f732e73616e6570
```

(those registers spell `ibdlopen` / `s/libdlo` / `penas.so`, the same register signature the
production `plpgsql` fault had.)

After:

```
PASS: round 0..11: child dlopen + dlsym + call (status 0)
PASS: parent (the address space that did not load it) dlopen + dlsym + call
tst-fork-dlopen-as: 0 failures
```

### Proposed fix

Branch: `fix/elf-object-cache-address-space` on https://github.com/gburd/osv-1

On a `_files` cache hit, ask whether the object is mapped in the **calling** address space and,
if not, re-establish it there at its existing base. Re-mapping the segments alone is not
enough, and this cost me a build to learn: a writable segment is mapped `MAP_PRIVATE` from the
file, so it comes back with its **unrelocated** on-disk contents (zero GOT entries), and the
next call through the GOT faults at address 0 immediately after a *successful* `dlsym`. So the
remap also re-runs the object's relocations, re-applies the RELRO and text protections, and
runs its constructors for the new address space. Relocations are recorded relative to `_base`,
which does not change, so they rebuild a byte-identical GOT.

Two further details that are easy to get wrong:

* The per-object fork-shared range registration in `load_segment` must become one-shot. A
  remap covers virtual addresses that are already registered, and re-registering grows the
  process-global vector without bound while its realloc/free lands on the **calling** address
  space's fork arena rather than the shared kernel heap. Without this guard the test aborts at
  `fork_arena.cc: recover: h->magic == chunk_magic`.
* Objects with no backing file (the kernel's own `memory_image`) must be excluded; they are
  mapped by the boot path in every address space and cannot be re-read. Without this,
  `memory_image::read` throws `cannot load from Elf memory image` at boot.

**Options considered.** Making `_files`/`_modules` fully per-address-space is the most faithful
model, but it changes a process-global structure that `dl_iterate_phdr`, the unwinder and
`program::lookup` all read cross-AS, and it would give each address space a different `_base`
for the same library, which breaks function pointers passed between them. Having
`clone_address_space` also clone segment mappings for the slots it copies fixes only the
fork-child direction and does nothing for the AS0-as-second-consumer case that x86_64
demonstrates, and it makes every fork pay for libraries the child may never touch. Refusing the
cache hit and loading a second copy would give the same library two bases in one process and
break `RTLD_GLOBAL` symbol identity. Re-mapping lazily on the cache hit keeps one object, one
base and one set of symbol addresses process-wide, and costs nothing for address spaces that
never touch the library.

**Memory cost, stated explicitly.** Read-only and executable segments cost no additional
physical memory: the mapping is file-backed at the same file offsets, so the same pages are
used. Writable segments (`.data`/`.got`/`.bss`) do become a private per-address-space copy,
which is the semantically correct outcome for a forked process anyway (library globals are
per-process), and is the same cost a normal `dlopen` in that address space would have incurred.
For a PostgreSQL backend loading `plpgsql.so` that is a few pages per backend.

### Caveat on the fix

I have validated the mechanism, the fix and the regression test on aarch64 (Graviton3, KVM,
`conf_fork=1 fs=rofs`), and the fix compiles for both architectures. The x86_64 evidence above
is the *bug*, reproduced independently; I have not yet run the *fix* on x86_64. Given that the
fix is architecture-neutral and the x86_64 reproducer is standalone, that should be quick to
confirm, but it is untested there and I would rather say so than imply otherwise.
