# fork() on OSv via threads — design

## The hard constraint

Linux `fork()` gives the child a **private, copy-on-write duplicate of the parent's
entire address space** plus a copy of its file descriptors, signal state, etc. The
child and parent then diverge with no shared memory.

OSv is a **single-address-space unikernel**: every thread of every "application"
shares one address space. There is no MMU-enforced process isolation and adding it
would defeat OSv's purpose (it exists precisely to remove the process/syscall/context-
switch overhead). Therefore a *true* fork — where the child gets its own copy of all
writable memory — **cannot** be implemented without turning OSv into a normal kernel.

`sys_clone()` today rejects everything that isn't `CLONE_THREAD` with ENOSYS, and
`fork()`/`execve()` are stubs. This design implements the **useful, compatible subset**
of fork semantics using OSv threads, and is explicit about what it cannot do.

## What real programs use fork() for (target the achievable)

1. **fork() + exec() (the overwhelming majority).** The child immediately calls
   `execve()` to run a *different* program. The child never relies on inheriting the
   parent's writable memory — it throws it all away at exec. This is fully achievable:
   the fork's job is only to (a) return a child pid to the parent, (b) give the child a
   context in which its `execve()` launches the new program, and (c) let the parent
   `wait()` for it. OSv already has `application::run()`, which launches a program in a
   new thread in the shared address space — exactly the exec target.

2. **fork() with the child running a bounded amount of the *same* program's code, then
   `_exit()`** (e.g. a server that forks a worker per connection, a "double fork" to
   daemonize, a test harness). Achievable *with caveats*: the child thread shares the
   parent's memory, so writes are visible to the parent (NOT copy-on-write). Works
   correctly for children that only read shared state and write to their own fds /
   freshly-allocated memory; breaks silently for children that mutate shared globals
   expecting isolation.

3. **fork() as a memory-snapshot mechanism** (Redis BGSAVE, a GC that forks to walk a
   frozen heap, `posix_spawn` fallbacks). **Not achievable** — this genuinely requires
   address-space copy. Must be documented as unsupported.

## Design: three layers

### Layer A — `fork()` returns a child "process" backed by a thread

Implement `fork()` (and `sys_clone` without `CLONE_THREAD` / with an exit-signal) as:

1. Allocate a **child pid** (OSv thread ids already serve as pids; reserve one via a new
   thread created suspended).
2. Snapshot the parent state that Linux fork copies and that we *can* copy cheaply:
   - **File descriptors**: OSv fds are reference-counted `file` objects in a per-thread
     (really per-app) fd table. Duplicate the table (dup each fd → shared open-file
     description, matching fork semantics where parent/child share file offset).
   - **Signal dispositions + mask**: copy the parent's `sigaction` table and blocked mask
     into the child context.
   - **cwd, umask, environ**: copy.
   - **Address space: NOT copied** — the child shares it (the documented divergence).
3. In the parent, `fork()` returns the child pid. In the child thread, `fork()` returns 0.
   This is the trick: a single call site returns twice, like real fork. We implement it by
   having the child thread's entry resume *at the fork() return point* with rax=0. Because
   there is no separate address space, the child cannot resume the parent's C stack
   in-place; instead the child gets a **copy of the parent's user stack** (bounded, see
   Layer B) so its local variables and return address are its own.

### Layer B — the stack copy (the one piece of "address space copy" we do)

The child needs its own stack so that when both threads return from `fork()` they don't
clobber each other's locals. We copy **only the parent thread's current stack** (from the
current SP up to the stack base) into a fresh stack for the child, and fix up the child's
SP to the equivalent offset. This is O(stack-depth), not O(heap), so it's cheap and
bounded. The child then returns from `fork()` with its own stack; any function-local
state the child touches is private. Heap and globals remain shared (the documented
limitation). This makes fork()+exec() and "child does a bit of work then _exit/exec"
correct, because those paths only depend on the stack being private through the exec/exit.

### Layer C — `execve()` → `application::run()` (make fork+exec real)

Replace the `execve()` stub with a real implementation that:
1. Resolves the path (respecting the fs), builds argv/envp.
2. Calls `osv::application::run(command, args, /*new_program=*/true, env)` — a new elf
   namespace so the exec'd program gets a fresh set of globals (this is the closest OSv
   has to a fresh address space; it isolates the new program's ELF from the parent's).
3. The calling (child) thread **becomes** that application's main thread: it does not
   return (exec replaces the image), matching Linux. On the parent side nothing changes.
4. `execve()` on the *original* app thread (not via fork) is also now meaningful: it
   tears down the current app's user threads (via `unsafe_stop_and_abandon_other_threads`
   guarded) and runs the new program — a best-effort image replace.

Wire `posix_spawn`/`system()`/`popen()` on top so the common "spawn a helper" path uses
`application::run()` directly (skipping the fork stack-copy entirely — the efficient path).

## pid / wait plumbing

- A `fork()` child registers in a process table keyed by the child pid (thread id),
  holding its exit status. `waitpid()/wait4()` block on the child's completion (join the
  thread / the `application`), reap the status, and return it Linux-style
  (`WIFEXITED`/`WEXITSTATUS`). `SIGCHLD` is raised to the parent on child exit.
- `getpid()` returns the app main thread id (already the case); the child's `getpid()`
  returns its own reserved pid.

## Honest limitations (documented, returned as errors where detectable)

- **No copy-on-write / no memory isolation.** Child and parent share heap + globals. A
  child that mutates shared state expecting a private copy will corrupt the parent. This
  is inherent to a single-address-space kernel.
- **fork() purely to snapshot memory (Redis BGSAVE style)** does not work as intended —
  the "snapshot" is live shared memory. We cannot detect this at the syscall boundary, so
  it is a documented behavioral difference, not an error return.
- **Deep fork trees / fork bombs** create real threads; bounded by thread limits.
- **`vfork()`** maps to fork() (the child sharing memory is actually closer to vfork's
  contract, where the child borrows the parent's space until exec/exit — so vfork()
  semantics are arguably *more* faithfully served by this design than fork()).

## Test (the runnable check)

`tests/tst-fork.cc`:
1. fork()+execve() a trivial program, parent waitpid()s, asserts child's exit code.
2. fork(); child writes to its own stack local + a private malloc, `_exit(N)`; parent
   waitpid asserts N and that the parent's own stack local is intact (proves the
   stack-copy isolation).
3. fork() return-value contract: parent gets >0, child gets 0, getpid() differs.
4. vfork()+exec path.
5. Negative: document (not assert) the shared-heap divergence in a comment.

## Scope for the first PR

Layers A + B + C for **fork() + execve() + waitpid() + vfork()**, `sys_clone` extended to
accept the fork case, `posix_spawn`/`system` routed through `application::run()`, the
test, and a `documentation/fork.md` stating the model + limitations. `clone()` with
arbitrary namespace-unshare flags (CLONE_NEWNS etc.) stays ENOSYS.

## Implementation feasibility — CONFIRMED

arch/x64/clone.cc `clone_thread()` ALREADY implements the double-return mechanism
this design needs: it copies the parent's saved syscall-frame registers into the child,
zeroes the child's RAX (so the child "returns 0" from the syscall), and jumps the child
to the parent's continuation point. It was written for pthread_create (CLONE_THREAD),
where the CALLER supplies child_stack.

For fork(), the ONLY delta is Layer B: instead of a caller-supplied child_stack, allocate
a fresh stack, copy the parent thread's current user stack into it, and pass that as
child_stack. Everything else (register copy, RAX=0, jump-to-continuation) is reused. This
makes the double-return — the scary part — essentially free. aarch64 has the analogous
arch/aarch64/clone.cc to mirror.

So the implementation is: (1) drop the `!(flags & CLONE_THREAD)` ENOSYS gate in sys_clone
for the fork case; (2) add a fork() entry that allocates+copies the user stack and calls
into the clone_thread path with it; (3) dup the fd table + copy signal state before
starting the child; (4) pid/waitpid/SIGCHLD plumbing; (5) execve() -> application::run().
