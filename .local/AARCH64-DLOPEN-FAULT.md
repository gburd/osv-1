# aarch64: deterministic vm_fault failure populating a mapped ELF page (dlopen path)

2026-09-07, agent ff3a9ff1 on c7gd.metal. **Distinct bug from the x86 ARC-reclaim bug**,
despite the identical-looking backtrace. Both boxes terminated, 0 orphans.

## Symptom
Every plpgsql call faults, at 1 connection, deterministically:

    page fault outside application, addr: 0x000010000106f000
    PC: elf::object::dynamic_tag(unsigned int)+8
    mmu::vm_fault -> page_fault -> elf::object::lookup_symbol_deep -> dlsym
    X07/X12/X13 spell "/plpgsql" / "r/lib/pl" / "pgsql.so"

12 concurrent calls -> 12 faults, identical PC and address. 5 SEQUENTIAL calls, 2 s apart,
1 connection -> 5/5 fail. Plain SQL works (count(*) -> 200); a `language sql` function
works (f_sql() -> 42). Only the dlopen/dynamic-symbol path dies. Survives `ae077860c` +
`746e5bcd`.

## My alignment-gap hypothesis: REFUTED, while the address model was CONFIRMED to the byte

    PT_DYNAMIC vaddr = 0x4fd28
    PT_LOAD[3]       = 0x4ec88 + 0x1c18 -> end 0x508a0,  Align = 0x10000 (64K, as I suspected)
    4K math          -> maps [0x4e000, 0x51000), which CONTAINS 0x4fd28   => COVERED
    base 0x100001020000 + align_down(0x4fd28) = 0x10000106f000 == observed fault addr  OK
    base             + 0x4fd28                = 0x10000106fd28 == observed X00         OK

So `_dynamic_table` is computed exactly as I predicted (fault page and X00 both match to
the byte), and `Align=0x10000` is confirmed - **but the 4K arithmetic still covers
PT_DYNAMIC, so it is NOT an alignment gap.** My hypothesis is dead; the arithmetic it
predicted is what proves the real diagnosis.

## The real diagnosis: mapped-but-not-present, i.e. vm_fault cannot populate it

`ESR = 0x96000007`: EC=0x25 (data abort), ISS low 7 bits = **0x07 = translation fault,
level 3**. I checked the aarch64 entry path: `arch/aarch64/mmu.cc:96` special-cases only
**access-flag** faults (`ACCESS_FLAG_FAULT_LEVEL_3`, 0x0b / 0x4b when write), so a
translation fault correctly falls through to `vm_fault`. The dispatch is right.

**Therefore the bug is that `vm_fault` fails to fault in a VALID file-backed mapping on
aarch64** (an RW/RELRO page of a dlopen'd library), not a bogus pointer and not a missing
mapping. That is the open question for whoever fixes it.

## No workaround exists
`shared_preload_libraries=plpgsql` does NOT help: it converts the per-backend fault into a
**postmaster boot hang** (3 console lines, PG never starts, 0 faults). Control boot without
it reached "ready to accept" in 15 s. Same bug, moved earlier.

## Consequences
- **All 6 HammerDB TPROC-C procs are plpgsql**, so NOPM/TPM is unobtainable at ANY VU on
  this base. pgbench used instead (plain SQL).
- **The historical "aarch64 crashes at VU128" datum is VOID.** This reproduces at 1
  connection, so it was never a concurrency ceiling. It also predates `ae077860c` and
  survives it.
- The earlier "network wedge" was **not** a network bug: the same log contained the dlsym
  fault. A faulting backend takes down the net path while the postmaster survives. The
  agent retracted its own virtio-net suspicion. `OSV_RX_INLINE` was never exported
  (0 occurrences), confirming my inertness finding.

## Also found, worth its own bug
The OpenZFS **image-builder** crashes on aarch64: `/zfs.so set compression=off osv`
page-faults in the mkfs guest (`osv::application::run_main` backtrace). Worked around with
`fs=rofs` root + a separate OpenZFS data disk; the data path is still OpenZFS-on-NVMe.
