# fork() on OSv

OSv is a single-address-space unikernel: all threads of all applications share
one address space, with no MMU-enforced process isolation. This is deliberate,
it is where OSv's performance comes from. It also means Linux `fork()`, which
gives the child a **private copy-on-write duplicate of the parent's entire
address space**, cannot be implemented literally.

OSv instead provides a **thread-backed fork() emulation** that supports the
common, compatible subset of fork semantics. This document describes what works,
what does not, and why.

## What works

- **`fork()` twin return.** `fork()` creates a new OSv thread (the "child") that
  resumes at the `fork()` call site. `fork()` returns the child's pid to the
  parent and `0` to the child, exactly like Linux. The child runs on a **private
  copy of the parent's user stack**, so parent and child have independent local
  variables and call chains after the return.

- **`fork()` + `execve()`.** The child calls `execve()`, which launches the
  requested program as a fresh OSv application (its own ELF namespace) and makes
  the child thread that program's driver; a successful `execve()` never returns,
  as on Linux. The parent is a separate thread and is unaffected.

- **`waitpid()` / `wait4()` / `wait()`.** The parent reaps a child's exit status
  (Linux-encoded, use `WIFEXITED`/`WEXITSTATUS`). `WNOHANG` is supported.
  `SIGCHLD` is raised to the parent when a child exits.

- **`vfork()`.** Maps to `fork()`. Because the child already shares the parent's
  address space, this actually matches vfork's contract ("the child borrows the
  parent's memory until it execs or exits") more faithfully than it matches
  fork's copy contract.

- **`_exit()` / `exit()` in a child** ends only that child "process" (thread /
  app) and records its status for the parent, rather than shutting down the
  whole unikernel (which is what a top-level `exit()` still does).

## What does NOT work (and why)

- **Shared TLS (thread-local storage).** The forked child restores the parent's
  fsbase and thus shares the parent's TLS block, rather than getting a private
  copy. For OSv-native code and short fork+exec / fork+_exit paths this is fine.
  But a glibc/musl program that relies on **per-process private TLS after fork**
  will collide: e.g. stock multi-backend PostgreSQL boots its postmaster and
  listens, but its first internal `fork()`'d child hangs in the first nontrivial
  libc call (`getenv`) because parent and child share one TLS block. Making
  fork() copy TLS per child (glibc-TCB-layout-specific) is the next required step
  to carry real multi-process glibc workloads; until then such programs need the
  threaded model instead (see the multithreaded-postgres port).

- **Memory isolation.** The child shares the parent's heap and global variables
  (only the stack is copied). A child that **writes** to shared globals or
  heap-allocated data expecting a private copy will affect the parent. Code that
  only reads shared state and writes to its own fds or freshly-`malloc`'d memory
  before `exec`/`_exit` is fine; code that mutates shared state after fork is
  not. This cannot be fixed without adding process isolation to OSv.

- **`fork()` as a memory snapshot** (e.g. Redis `BGSAVE`, a GC that forks to walk
  a frozen heap). These rely on the child seeing a *frozen* copy of the parent's
  memory at fork time. On OSv the child sees live, shared memory. This is a
  silent behavioral difference (it cannot be detected at the syscall boundary)
  and is **unsupported**.

- **Stack-internal pointers.** Because the child's stack is a byte copy of the
  parent's biased to a new address, a pointer stored on the stack that points
  *into the same stack* still points at the parent's stack in the child. Short
  child code paths (the fork+exec and fork+work-then-_exit patterns) do not hit
  this; long-lived divergent children can. A future refinement could scan and
  fix up such pointers.

- **`clone()` with namespace-unshare flags** (`CLONE_NEWNS`, `CLONE_NEWPID`,
  etc.) returns `ENOSYS` — there are no namespaces to unshare.

- **aarch64.** Implemented and validated: the stack-copy + `br` resume
  trampoline works on aarch64 (Graviton) as well as x86-64. `tst-fork` passes
  10/10 on both architectures.

## Implementation

- `libc/process/fork.cc` — `fork()`/`vfork()`, the child registry, and the
  `waitpid()` backend + `SIGCHLD` notification.
- `arch/x64/fork.cc` — `fork_thread()`: allocates a fresh stack, copies the
  parent's current user stack into it, and returns a child thread that installs
  the copied stack and returns `0` from `fork()`. Reuses the register/
  continuation approach of `clone_thread()` (used by `pthread_create`).
- `libc/process/execve.cc` — `execve()` via `osv::application::run()`.
- `libc/process/waitpid.cc` — `wait`/`waitpid`/`wait4`.
- `runtime.cc` — `exit()` ends a child rather than shutting down OSv.
- `linux.cc` — `sys_clone()` routes the non-`CLONE_THREAD` (fork) case here.

## Guidance

For spawning helper programs, prefer `posix_spawn()` or `system()` (which route
straight to `osv::application::run()` and skip the stack copy entirely) over
`fork()`+`exec()` where you control the code. Use `fork()` for compatibility
with existing Linux programs that expect it, within the limitations above.
