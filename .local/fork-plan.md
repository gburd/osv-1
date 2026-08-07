# OSv fork() — full plan toward Linux-compatible semantics

## Where we are (validated)
Thread-backed fork()/vfork()/waitpid() works: tst-fork 10/10 on x86-64 AND
aarch64. The child is a real OSv thread that resumes in fork()'s caller on a
PRIVATE COPY of the parent's stack, with its own fresh OSv TLS block (errno etc).
fork+exec, fork+_exit, vfork, waitpid + SIGCHLD all work. execve() has a separate
pre-existing app::run(new_program) fault (deferred).

## The core question: is COW-private memory part of the Linux fork contract?
YES — it is the essence of fork(). After fork() the child gets a logically
independent copy of every PRIVATE mapping (heap/brk, .data/.bss, MAP_PRIVATE
mmaps, stack), realized lazily by copy-on-write. MAP_SHARED mappings and POSIX
shm STAY shared (this is how PostgreSQL shared_buffers works: intentionally
shared across backends, while each backend's heap/globals are private).

## Can threads provide the identical contract? The single-address-space wall
OSv has ONE global vma_list / ONE address space (core/mmu.cc:118). All threads
share the same page tables at the same virtual addresses. Linux fork gives the
child the SAME virtual addresses mapped to DIFFERENT physical pages. In one page
table, address X cannot mean different physical pages for two threads at once.
So "just mark the segments COW inside fork()" CANNOT work as-is: a COW write
fault at address X would have to resolve to different physical pages depending
on which thread faulted, which a single shared page table cannot express.

OSv DOES already have the ingredients COW needs: per-page write-protect PTEs
(core/mmu.cc:253 set_writable), write-fault detection (is_page_fault_write), a
working MAP_PRIVATE copy-on-write path (pagecache.cc), and a vma model
(anon_vma/file_vma) that can be cloned. What is missing is PER-CHILD PAGE-TABLE
CONTEXTS.

## Options for true COW fork

### Option A — threads, shared everything (current)
No memory isolation. Carries fork+exec, system(), and children that only READ
shared state. Does NOT carry multi-backend PostgreSQL (backends mutate private
heap/globals expecting isolation). Zero further work. This is the honest
baseline fork() ships as.

### Option B — per-child address space with COW (the real fork)
Give each forked child its OWN page-table root (CR3 on x64 / TTBR0 on aarch64)
and its own vma_list. On fork:
  - Clone the parent's vma_list into the child's.
  - For every PRIVATE, writable mapping: write-protect BOTH parent and child
    PTEs and mark the vma COW; the first write in either faults, copies the
    page, and re-grants write to the faulting side. (Reuse the existing COW
    fault machinery.)
  - MAP_SHARED / shm vmas: map the SAME physical pages in the child (truly
    shared) — do NOT COW them. This preserves PG shared_buffers semantics.
  - Kernel address range (OSv text/data/kernel heap) stays identically mapped
    in every address space (like Linux kernel-half sharing), so OSv code and
    the shared kernel heap work unchanged across the switch.
Then the scheduler must switch the active page-table root on context switch when
moving between threads in different address spaces, and vm_fault must resolve
against the current thread's address space + vma_list.
COST: this is a genuine change to OSv's "single address space" invariant — the
biggest piece. But the vma + COW primitives exist; the new work is (1) an
"address space" object holding a page-table root + vma_list, (2) per-thread
current-address-space + switch on context switch, (3) fork cloning the AS with
COW, (4) fault path keyed on current AS. Bounded and well-understood; it is how
every real kernel does fork. This is required to run stock multi-process
PostgreSQL.

### Option C — private mappings at different virtual addresses (rejected)
Copy private mappings to NEW addresses in the shared space. Breaks any pointer
into the parent's memory; only works for fully relocatable code. Not viable for
PostgreSQL. Rejected.

## Decision
Ship Option A now (validated, useful for fork+exec/system and read-only-share
children), and pursue Option B as the path to multi-process glibc/musl workloads
(PostgreSQL). Option B is staged below.

## Other Linux fork() policy gaps to close (audit)

| # | Linux contract | OSv today | Fix |
|---|---|---|---|
| 1 | Child gets COW-private copy of PRIVATE mappings; SHARED stay shared | shares everything (one AS) | **Option B** (per-child AS + COW) |
| 2 | Only the CALLING thread survives in the child (multithreaded parent -> single-threaded child) | ALL of parent's OSv threads still exist and run | On fork, the child AS must start with ONLY the forked thread; other parent threads must NOT be present/runnable in the child context. With per-AS threads (Option B) this falls out; under Option A it's a real hazard (sibling threads run in the "child"). Document + (B) fixes. |
| 3 | Signal handlers copied; signal mask inherited; PENDING signals NOT inherited | handlers/mask are process-global (shared) | Copy sigaction table + mask into child; clear child's pending set. Small. |
| 4 | pthread_atfork prepare/parent/child handlers run | not run | Call __register_atfork chain: prepare() in parent before fork, parent() in parent after, child() in child after. OSv already stores atfork handlers (libc/pthread.cc register_atfork) — just invoke them. Small + high-value (glibc/musl call it internally). |
| 5 | getppid() = parent pid; child has no children | getppid stubbed | Track parent pid in the child registry (fork.cc already has parent_pid); wire getppid(). Small. |
| 6 | fds: child copies referencing SAME open-file-description (shared offset) | fds process-global (shared) | Under Option A fds are shared (offset shared) which matches the OFD-sharing part; but child should get an independent fd TABLE (close in child != close in parent). Give the child AS its own fd table referencing the same struct file*. Medium (ties to Option B AS object). |
| 7 | itimers/CPU timers reset; mlock not inherited; rusage reset | n/a mostly | Reset per-child; low priority. |
| 8 | Robust futexes / locks in shared memory copied as-is (may deadlock) | same hazard | Inherent; document. atfork (#4) is the app-level mitigation. |

## Staged implementation plan

**Stage 0 (done):** thread-backed fork + private stack + fresh TLS + waitpid +
SIGCHLD + vfork. 10/10 both arches.

**Stage 1 (small, do now, no AS change): close the cheap policy gaps.**
- pthread_atfork handlers invoked around fork (#4).
- Copy signal handlers + mask to child, clear pending (#3).
- getppid() wired to the child registry (#5).
- These make fork() more correct for real programs even under Option A, and are
  prerequisites glibc/musl fork wrappers expect.

**Stage 2 (the big one): Option B — per-child address space with COW.**
- Introduce an `mmu::address_space` object: a page-table root + a vma_list +
  an fd table. The current single global becomes "address space 0" (the kernel
  + init app).
- Per-thread `current_address_space`; switch the page-table root on context
  switch (arch hook: load CR3 / TTBR0). Kernel range identity-mapped in all.
- fork(): create a child address_space, clone the parent's vmas; write-protect
  private writable vmas in both + mark COW; share MAP_SHARED/shm vmas; give the
  child its own fd table (same struct file*).
- vm_fault resolves against current thread's address_space; COW write fault
  copies the page + re-grants write (reuse existing COW code).
- Only the forking thread exists in the child AS.
- This is the milestone that lets stock multi-process PostgreSQL run.

**Stage 3: validate** — musl PostgreSQL forks a backend per connection, serves
queries (single + concurrent), then HammerDB vs Linux.

## Risk / honesty
Stage 2 touches OSv's defining invariant (single address space) and its
performance model (address-space switches reintroduce some of the TLB/context
cost OSv exists to avoid — though only between fork children, not for the common
single-app case). It is the correct and only way to a faithful fork(), and every
primitive it needs already exists in OSv; it is substantial but not research.
Ship Stage 0+1 as a reviewable PR (honest scope); pursue Stage 2 as the
multi-process-enablement follow-up.

## CRITICAL UPDATE (from musl-PG test): the stack-relocation bias bug

musl PostgreSQL got PAST the TLS/getenv wall (musl + fresh-per-child OSv TLS +
atfork all work) but the forked child crashed (rip=0) while returning UP a deep
call chain (fork_process -> postmaster_child_launch -> ...).

Root cause: the current fork COPIES the parent's stack to a DIFFERENT virtual
address and biases the child SP by (child_base - parent_stack_base). Saved
RETURN ADDRESSES survive (absolute code addrs), but saved FRAME POINTERS (RBP)
and any `&local` on the copied stack still point at the PARENT's stack, off by
`bias`. A shallow caller (tst-fork) survives; a deep chain (PostgreSQL) hits a
frame whose biased RBP/leave unwinds into the parent stack -> corruption -> rip=0.

This UNIFIES with Stage 2: the fix is NOT frame-pointer rewriting (fragile,
misses &local pointers). The fix is per-child ADDRESS SPACE: the child's stack
must live at the SAME virtual addresses as the parent's, backed by PRIVATE COW
pages. Then there is NO bias - saved RBPs, return addresses, and stack-internal
pointers are all valid, and writes diverge via COW. So Stage 2 (per-child AS +
COW) is the correct fix for BOTH the heap-isolation requirement AND this stack
bias bug. The stack-relocation approach in arch/*/fork.cc is a stopgap that only
works for shallow callers and MUST be replaced by same-VA-COW-stack under Stage 2.

Stage 2 STEP 3 amendment: the child's stack (and all private mappings) keep
their ORIGINAL virtual addresses in the child address space; only the backing
pages are COW-privatized. No SP bias, no stack copy to a new address. tst-fork
AND deep-chain callers (PostgreSQL) then both work.

## Stage 2 RESULT (implemented, gated, COW proven; deep-stack gap identified)

DONE + VALIDATED (branch wip/fork-stage2, on gated feat/fork):
- address_space object (pt root + vma_list) [1e60296f], per-thread current-AS +
  CR3 switch on context switch, guarded so it only reloads when AS differs
  [5dd390bf], COW clone-on-fork [6192f5d9], ALL gated behind CONF_fork [2b4ceaf2]
  (zero cost when off).
- tst-fork-cow PROVES it: forked child's private memory stays private, MAP_SHARED
  stays shared. tst-fork 10/10 (fork/fork+exec/vfork/waitpid). execve() returns
  the thread to AS0 [c818f541]. destroy_address_space frees private pt/COW leaves,
  skips shared+kernel slots.

THE DEEP GAP (honestly diagnosed, correct revert):
- Deep-call-chain child unwind (tst-fork-deep, forks 12 frames deep) needs the
  child stack at the SAME VA (COW), not copied+biased. Same-VA stack WAS
  implemented but REVERTED because it exposed: OSv HAS NO SEPARATE KERNEL STACK -
  kernel code (e.g. child_exited's g_lock) runs on the APP stack. A shared kernel
  mutex's wait_record allocated on a privatized same-VA stack maps to DIFFERENT
  physical pages in parent vs child AS -> lockfree::mutex unlock assertion when
  parent+child contend. Retained the proven copy+bias model (shallow fork/exec/
  vfork/COW correct; deep unwind is the known gap).
- CORRECT FIX (bounded, non-trivial follow-up): run the child's in-kernel lock
  ops on memory reachable identically in both AS - either a real per-thread kernel
  stack (OSv's big structural gap), OR keep the forking thread's app stack SHARED
  and give the child a private stack the kernel never parks wait-records on, OR
  ensure kernel wait-records are allocated off-stack (in AS-shared memory).
- Other gaps: (2) mmap/munmap in a forked child still hit the GLOBAL vma_list
  (execve sidesteps by returning to AS0); wire mmap to current AS's vma_list.
  (3) arch_prctl-installed TCB (glibc) still shared; musl path clean.

BOTTOM LINE: per-child COW address space works + is proven + gated. Real
multi-process PostgreSQL still needs the same-VA stack, which is blocked on OSv's
no-separate-kernel-stack design - the next concrete, bounded piece.
