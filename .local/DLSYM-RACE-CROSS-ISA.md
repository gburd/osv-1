# Kernel faults in dlsym/ELF symbol lookup (TWO probably-distinct bugs)

**REVISED 2026-09-07 (later): my "same bug on both ISAs" framing is probably WRONG.**
The aarch64 arm's characterisation refutes the race hypothesis for aarch64:
  - 12 concurrent plpgsql calls -> 12 faults, ALL at the SAME PC and SAME address
  - 5 SEQUENTIAL calls, one at a time with 2 s gaps -> 5/5 fault, at 1 connection
Deterministic, single-threaded, identical address is NOT race-shaped. So:
  - **aarch64 = deterministic ELF-loader bug in the dlopen path** (every plpgsql call)
  - **x86_64 = ONE fault in 68k console lines** = still race-shaped, possibly a
    different and rarer bug
They are now tracked as potentially separate. Tight aarch64 isolation supports this:
plain SQL works (`select count(*) from warehouse` -> 200), a `language sql` function
works (f_sql() -> 42), plpgsql.so IS in the image (1.05 MB, /usr/lib manifest) and parses
far enough to emit a plpgsql SYNTAX ERROR before dying in dynamic_tag(). Only the
dlopen/dynamic-symbol path faults.


2026-09-07. Found INDEPENDENTLY by both benchmark arms, on two ISAs, on two different
bases. This is the most valuable result of the campaign and it is a genuine OSv kernel
bug, not a benchmark artifact.

## The corroboration that makes it credible

    x86_64   addr 0x0000100000f46000  RIP elf::object::dynamic_tag(unsigned)+12
             page_fault+139 -> elf::object::lookup_symbol_deep+29 -> dlsym+268
             base HAS ae077860c, dad77b7f, 746e5bcd

    aarch64  addr 0x00001000010bf000  PC  elf::object::dynamic_tag(unsigned)+8
             mmu::vm_fault -> page_fault -> elf::object::lookup_symbol_deep -> dlsym
             base LACKS all three; registers spell "plpgsql.so" / "/lib/pl"

`include/osv/elf.hh:568`: `program_base = 0x100000000000UL`. So both faults land just
inside the shared-object mapping region:

    x86     program_base + 0xf46000   = +15.3 MB
    aarch64 program_base + 0x10bf000  = +16.7 MB

Same call path, same region, same library (plpgsql), **two ISAs and two different bases**.
That rules out base staleness (my initial theory for the aarch64 arm), rules out an
ISA-specific bug, and rules out the three tail-latency fixes as either cause or cure.

## Mechanism (hypothesis, source-derived, handed to the arm to confirm or kill)

`dlsym` at `libc/dlfcn.cc:78` calls `obj->lookup_symbol_deep(name)` holding **no lock**.
`lookup_symbol_deep` (`core/elf.cc:1104`) calls `collect_dependencies_bfs()`, which walks
`obj->_needed` (a `std::vector<std::shared_ptr<object>>`) and dereferences each element.

Concurrently, `object::load_needed` (`core/elf.cc:1202`, `_needed.push_back` at :1226) and
`object::unload_needed` (:1233, `_needed.pop_back()` at :1237-1238) MUTATE that vector.

Other parts of elf.cc are carefully locked - `s_objs_mutex` (:1737-1747),
`_modules_delete_mutex` (:1730, :2029), `_module_index_list_mutex` (:1962, :1983),
`_used_by_resolve_plt_got_mutex` (:960) - but **this walk is not**.

So a PG backend calling `dlsym` on plpgsql while another backend loads/unloads shared
objects can walk a vector being reallocated underneath it, yielding a dangling `object*`
and a fault inside `dynamic_tag()` at a plausible-looking address. This explains both the
rarity (one fault in 68k console lines) and the requirement for concurrent backend churn.

## The aftermath is worse than a panic (and this matters for methodology)

The guest does NOT die. qemu keeps burning 126% CPU and the postmaster keeps logging, but:
- the network stack goes permanently deaf: stops answering ARP (`ip neigh` = INCOMPLETE),
  100% ping loss, unreachable **from the host too**, not just the driver;
- fork is wedged: "autovacuum worker took too long to start; canceled" 39 times, one
  every ~15 s, forever;
- the connect probe recorded **138 of 139 fresh connects FAILED** (the single success was
  pre-crash).

**A naive harness records "connection refused" and blames the network.** This failure mode
silently corrupts benchmark results, which is precisely why the independent connect probe
and full console capture are mandatory instruments rather than nice-to-haves.

## Next steps set
1. Confirm or kill the race with a **targeted reproducer**: N threads dlsym-ing while M
   threads dlopen/dlclose the same library. Guest-local, no PostgreSQL, no driver, cheap.
2. Characterise the zombie state and report why it is dangerous for benchmarking.
3. Sweep coverage last. **A characterised cross-ISA kernel race beats a complete NOPM
   table.**

No PR yet, deliberately: a lock in the dlsym path has scheduling implications and may
need an RCU-style or shared-lock approach rather than a mutex, since dlsym sits on hot
paths. Decide the fix design after the reproducer confirms the mechanism.

## Side result supporting an earlier prior
The x86 crash hit during "checkpoint starting: wal" immediately after a checkpoint that
wrote 847,791 buffers (40.4% of a 16 GB shared_buffers) in **128.4 s**. That independently
supports the standing "I/O-bound on WAL/COW before vCPU-bound" finding.

## aarch64 mechanism hypothesis: PT_DYNAMIC outside any mapped PT_LOAD

`core/elf.cc:530` sets `_dynamic_table = _base + phdr.p_vaddr` from **PT_DYNAMIC**, and
`_dynamic_tag()` walks `for (auto p = _dynamic_table; p->d_tag != DT_NULL; ++p)`, so it
faults on the **first dereference** if that address is unmapped.

Mapping is done by `file::load_segment` (`core/elf.cc:417`) for **PT_LOAD only**:

    vstart = align_down(p_vaddr, mmu::page_size);
    memsz  = align_up(p_vaddr + p_memsz, mmu::page_size) - vstart;

and `include/osv/mmu-defs.hh:22-23` hardcodes **page_size = 4096 on aarch64 too**.

Hypothesis: plpgsql.so's PT_DYNAMIC vaddr falls outside every mapped PT_LOAD range (or on
a page the alignment math drops), so `_dynamic_table` is a plausible-looking pointer into
unmapped space. Deterministic, same address every time, at 1 connection - matching the
measurement exactly.

**Prime suspect: 64K segment alignment.** aarch64 distro toolchains commonly use
`PT_LOAD Align = 0x10000`. If plpgsql.so was built with 64K segment alignment while OSv
maps with 4K math, that is a very plausible route to an unmapped gap. The
`-mno-outline-atomics` requirement already tells us this was built with a distro aarch64
toolchain.

**Decisive test costs one readelf plus arithmetic, no guest run:** dump PT_DYNAMIC's
VirtAddr and every PT_LOAD's VirtAddr/MemSiz/Align; check whether PT_DYNAMIC lies inside
some PT_LOAD after align_down/align_up; and confirm the fault address arithmetically -
the fault at `0x10000106f000` is `program_base + 0x106f000` (program_base =
0x100000000000, `include/osv/elf.hh:568`), so subtracting the object's `_base` should
yield PT_DYNAMIC's p_vaddr if the mechanism is right.

## Scope change: aarch64 cannot produce a throughput number on this base

All 6 HammerDB TPROC-C stored procedures are plpgsql (neword/payment/delivery/slev/ostat
+1), so every transaction calls one and NOPM/TPM is unobtainable at ANY VU. Deliverable
changed to: the characterised bug; the explicit statement that the earlier VU8 crash and
the **historical VU128 crash are very likely BOTH this bug rather than a concurrency
ceiling** (which retroactively VOIDS that VU128 datum); the substrate + durability proofs
already obtained; and pgbench numbers instead of HammerDB if cheap, since pgbench's
default workload is plain SQL with no plpgsql.

## Base note
Applied: `ae077860c` + `746e5bcd`, clean, new SHA **eb164dcd**. `dad77b7f` **deliberately
excluded**: it conflicts semantically in `core/mmu.cc` because the aarch64 branch's
"NESTED-FAULT SAFETY exception_depth>=2 lock-free COW" block and dad77b7f's
`cow_peek_enabled()/write_fault_needs_cow_lock()` lock-skip both rewrite the same
`if (is_page_fault_write(...))` condition. Aborting was correct: this is the established
"when two guards target the same acquisition for different reasons, BOTH conditions must
hold" trap, where taking either side wholesale reintroduces a bug.

## x86 arm: my dl-bookkeeping race hypothesis TESTED AND REFUTED

Two targeted reproducers, both survived clean. This is a decisive negative, not an
untested guess:

    dlrace  (same-process, exactly my mechanism):
      16 threads dlsym on an open handle + 16 threads dlopen/dlclose the same
      plpgsql.so to churn _needed via push_back/pop_back
      -> 582,429,800 dlsym and 5,595,884 dlopen/dlclose in 90 s, fail=0, NO FAULT

    dlrace2 (fork-based, since the real fault said "outside application" i.e.
      invalid in the FAULTING AS):
      40 rounds x 16 forked children, each dlopen/dlsym/dlclose plpgsql in its own
      COW address space while the parent races in its own; 640 forks
      -> 20,000 parent dlsym, child_failures=0, all rounds clean, NO FAULT

582M concurrent dlsym against 5.6M vector mutations without a single fault is far past
where a plain vector-realloc-under-walker race would have fired thousands of times. **My
unlocked `_needed` walk is not the faulting path.** Recorded as refuted-with-numbers, not
as unexplored: it permanently removes the most obvious suspect and stops the next person
re-litigating it.

## The better hypothesis: ARC/pagecache reclaim unmaps the page under the walker

The agent's correlate is the CHECKPOINT (fault landed exactly at "checkpoint starting:
wal", right after 847,791 buffers / 40.4% of 16 GB written in 128.4 s). I found the
supporting path in source:

- ELF segments are mapped with `mmu::map_file` (`core/elf.cc:445`), so shared-object
  text/data pages are **file-backed and pagecache/ARC-resident**, not anonymous.
- `core/pagecache.cc` has `unmap_arc_buf` (:339) and `remove_mapping` (:403-406) calling
  `cp->unmap(ptep)` (:221, :397) then `mmu::flush_tlb_all()` (:350).

So **ARC eviction can unmap a file-backed page belonging to a loaded shared object.** If
reclaim pulls the page holding plpgsql.so's `_dynamic_table` while a thread is mid-walk in
`_dynamic_tag()`, the result is exactly "page fault outside application" at a
plausible-looking address inside `program_base` - and only under heavy ARC pressure.

This also explains why BOTH reproducers passed: **neither generated ZFS/ARC memory
pressure.** dl bookkeeping concurrency was never the missing ingredient.

Adjacent and worth flagging: patches `0030-zfs-arc-eviction-waiter-on-identity-heap-for-fork`,
`0031-zfs-cap-default-ARC-at-half-RAM`, `0032-zfs-synchronous-ARC-shrinker-hard-mode` are
all on this base and all concern ARC eviction under fork.

Next cheap step requested: rerun the existing reproducers WITH ARC pressure (big sequential
I/O / scrub / write load) rather than building anything new. If it faults, a correlation
becomes a reproducer and that is the whole bug. Candidate fixes to weigh only after that:
pin/mlock file-backed pages owned by loaded ELF objects against reclaim; make the
dynamic-table walk fault-tolerant; or have reclaim skip mappings owned by elf objects.

## Methodological note
Two of my hypotheses killed by measurement in one session (the fork TLB/IPI mechanism
earlier, this dl race now), plus the aarch64 determinism refuting the shared framing. The
pattern: I generate plausible mechanisms from source reading and do not cost-check them
against the observed magnitude or shape before briefing them as targets. The guard that
keeps working is asking the agent to REPRODUCE the mechanism in isolation first - cheap,
and it either confirms or kills the story before a fix is attempted.
