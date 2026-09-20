# OSv fork per-backend footprint study — PROGRESS (live)

## BOXES (Owner=agent-footprint, us-east-2) — TERMINATE at end, confirm 0 orphans
- METAL: `i-0386137bc2f8d0dbb`  m5d.metal  (OSv guest + host + instrumentation), launched 17:27 UTC
- DRV:   `i-0b6ee4b1cad272444`  c5.4xlarge (HammerDB VU driver)
- Base: gh-fork/bank/fork-arena-real-reclaim (43fcdca79), apps 3f93f43 (mkdir gate = 1 VERIFIED)
- Gate markers verified on-box: stack_guard=3, wake_pull_enabled=1, OSV_FORK_RANGE_BS=2,
  OSV_FORK_LARGE_SHARE=2, SEEDCOPY_MKDIR_FIX=1.
- Work branch: `bank/fork-footprint-reduction` (local worktree /tmp/fpwt, commit 95fd7385b)

## SOURCE READING (done before any measurement; each claim has a file:line)

### (a) the fork arena — 512 MiB, EAGERLY POPULATED, GLOBAL bump, NO reuse across processes
`core/fork_arena.cc`:
- `init()` maps `arena_base = 96<<39`, `arena_size = 512 MiB` with `mmap_fixed | mmap_populate`.
  **Every one of the 131072 arena pages is real RAM in the parent at init.** That is load-bearing:
  `alloc()` may be entered IRQs-off, where a demand fault would trip
  `page_fault`'s `assert(preemptable && irq_if)`.
- The bump pointer `g_bump` is **GLOBAL across every address space** (comment: "carves each fresh
  chunk a VA that is unique across EVERY address space"). The free-lists are **per-AS**.
- CONSEQUENCE (the key structural finding, to be confirmed by measurement): a fresh fork child
  inherits the parent's per-AS free-lists NOT AT ALL (it gets its own empty slot via
  `slot_for(current_address_space())`). So **every allocation a new backend makes is a fresh
  bump carve at a never-before-touched VA**, and each such carve first-touches a page that
  *already exists in the parent* → a COW break → a real private page per touched arena page.
  A backend cannot reuse the parent's freed arena space; it can only reuse its own.
- The bump is monotone and global: N backends each carving M bytes advance g_bump by N*M.
  512 MiB / N backends is the per-backend arena budget before exhaustion → at 74 backends that
  is ~7 MiB each, and past that `overflow_alloc()` maps **per-AS 1 MiB `mmap_populate` regions**
  in slot 97 (eager again → every overflow page is real RAM the moment it is mapped).

### (b) the page-table clone — already largely fixed on this base
`core/mmu.cc` `clone_pt_level<1>` has `range_is_wholly_shared()` (OSV_FORK_LARGE_SHARE, default ON):
a writable 2 MiB large page fully inside a MAP_SHARED range is **shared verbatim, not split**.
So the brief's worry — "split_large_page mutates the PARENT permanently per fork, killing
hugepages" — is ALREADY CLOSED on this base for MAP_SHARED (i.e. shared_buffers). The remaining
split path only fires for writable large pages that are NOT wholly inside a share range
(large private malloc / large anon). `free_child_pt_level<1>` skips large entries, so the
jointly-owned 2 MiB frame is never freed by a dying child. **No regression vs 3364d5c68; the
commit's guarantee is what `range_is_wholly_shared` implements.** Still to MEASURE: how many PT
pages a clone actually allocates now (the probe counts PML4 + L2 + L1 + leaf per child).

### (c) stacks / TLS
- kernel thread stacks: `arch/x64/arch-switch.hh` `init_stack()` — `CONF_threads_default_kernel_stack_size`,
  forced onto the **identity heap** (`fork_arena::kernel_heap_scope`), so a stack is NOT COW'd;
  the forking thread's live stack is byte-COPIED per child (`addr_is_privatize` in `clone_pt_level0`).
  The probe counts those copies as `priv_KB`.
- other live threads' stacks are SHARED (share_ranges), not copied.

### (d) genuine PG private — the residual, computed as (measured total) − (a+b+c).

## HYPOTHESIS GOING INTO MEASUREMENT (to be confirmed or refuted by the table)
The dominant term is (a), and the amplifier is **not** COW of live data but the combination of:
  1. eager `mmap_populate` (every arena page is real RAM in the parent, so a COW break
     materializes a *second* real page even for logically-free arena space), and
  2. the **GLOBAL monotone bump + per-AS-only reuse**: a fresh backend cannot reuse any arena
     space the parent or a dead sibling freed, so it walks fresh VA and COW-breaks fresh pages
     for its entire heap lifetime rather than recycling a small working set.
If the FPROW `cowarena_KB` per backend is the bulk of ~700 MB, that is confirmed.

## STATUS
- [x] boxes launched, host bootstrapped, driver setup running
- [x] FP probe written, applied cleanly to the base, committed (95fd7385b)
- [ ] image build with the probe (in flight)
- [ ] seed + VU measurement + the breakdown TABLE
