# T3 — libc stubs / UNIMPL audit: reachability & hazard

Copyright (c) 2026 Greg Burd. BSD-3-Clause.

Read-only audit of four libc stubs on `master`. For each: exact runtime behavior, reachability
from musl / common apps, severity, fix recommendation and rough size. All citations are `file:line`
on `master`.

## Shared fact: what UNIMPL does

`include/osv/stubbing.hh:52` `#define UNIMPL(decl) decl { UNIMPLEMENTED(#decl); }`, and
`:41` `UNIMPLEMENTED` = `WARN(...)` then **`abort()`**. So any `UNIMPL`-defined function **crashes
the unikernel (SIGABRT) on first call** — not ENOSYS, not a no-op. Contrast `NO_SYS` (`:46`) which
sets `errno=ENOSYS; return -1`.

## Per-item findings

| Item | Current behavior | Reachability | Severity | Recommendation | Size |
|---|---|---|---|---|---|
| `_pthread_cleanup_push/pop` (`libc/pthread.cc:1264-1265`) | **No-op bodies that ignore `run`.** Public macro `pthread_cleanup_pop(1)` (`include/api/pthread.h:212`) is supposed to invoke the handler on normal pop; the stub silently drops it. Handlers NEVER run — not on cancel, not on `pop(1)`. | Public `pthread.h:211-212` ships the real musl macro to every app. Any threaded C using `pthread_cleanup_push/pop` is affected (common idiom for unlock/free on exit). Internal musl is NOT affected: `__stdio_read.c:4` includes `pthread_stubs.h` which `#undef`s the macro to a local no-op, and it only uses `pop(0)`. `__dns.cc:71-72` shows the authors hit this — the `//pthread_cleanup_pop(1)` is commented out and replaced by a direct `cleanup(...)` call. | **HIGH** | Implement the two functions for real against `struct __ptcb` (`pthread.h:202`): push links `__cb` onto a per-thread list; `pop(run)` unlinks and, if `run`, calls `__f(__x)`. Cancellation path can stay inert (`pthread_cancel` is itself a stub, see below) — only `run!=0` must execute. | Small (~25-40 LOC + a thread-local list head). |
| `sigsuspend` (`libc/signal.cc:249`) | **abort()** on first call (UNIMPL). Not a soft error. | Exported (`osv_ld-musl.so.1.symbols:994`). Called by signal-driven wait loops; musl internals do not call it on common paths (no caller in-tree besides the stub). Apps that `sigsuspend()` to wait for a signal will crash. Narrow but fatal. | **MEDIUM** | Minimum: honest-ENOSYS via `NO_SYS` so callers get `errno=ENOSYS` instead of killing the VM. Real impl is possible on top of the existing `sigprocmask`/signal machinery (`signal.cc:230-246`) but is more work and OSv signal delivery is limited. ENOSYS first. | Tiny for ENOSYS (1 line). Real impl: medium. |
| `getrandom` + `GRND_NONBLOCK` (`libc/random.c:30-33`) | Honors neither blocking nor non-blocking; when `GRND_NONBLOCK` set it returns **`errno=ENOSYS`, -1** (`:31`). Linux returns `EAGAIN` when entropy is unavailable, never ENOSYS for the flag. OSv's `/dev/random` never blocks anyway, so the flag could just be ignored and the call would succeed. | Exported (`osv_libc.so.6.symbols:312`); reachable by getrandom non-blocking callers (some crypto/init code). Narrow. Soft error, no crash. | **LOW** | Ignore `GRND_NONBLOCK` and proceed — OSv's source never blocks, so non-blocking semantics are trivially satisfied. Drop the ENOSYS branch; document that `flags` is advisory. (Tangent, out of scope: `getentropy` `:62` returns `getrandom(...)>=0` i.e. 1/0, not Linux's 0/-1 — pre-existing, note only.) | Tiny (delete 4 lines / 1-line change). |
| `dlvsym` (`libc/dlfcn.cc:88-91`) | Warns once, then **falls back to `dlsym`** ignoring the version string (`:90-91`). Returns the unversioned symbol — may be the wrong version, but does not crash. | Exported (`osv_libdl.so.2.symbols:6`). Needed only by glibc-ABI libs doing versioned symbol lookup; rare in OSv's musl world. No in-tree caller. | **LOW** | Document the limitation (WARN_ONCE already present). Honest-ENOSYS (`return NULL` + set dlerror) is arguably more correct than returning a possibly-wrong version, but the dlsym fallback is usually what the caller wants. Leave as-is + comment, or add dlerror on true mismatch later. | None (document) or tiny. |

## Verdict

**Fix `_pthread_cleanup_push/pop` first.** It is the only item that is (a) silently wrong on a
normal, common code path — `pthread_cleanup_pop(1)` must run its handler and does not — and (b)
widely reachable, since the public `pthread.h` macro hands it to every threaded C program. The
failure mode is invisible: skipped unlocks, un-freed buffers, and un-run teardown on normal thread
exit, with no warning and no crash to flag it. The authors already worked around it internally
(`__dns.cc:71-72`), which both confirms the bug and shows the real fix is small and localized.
`sigsuspend` is second: it is a hard `abort()` (VM kill), but narrow — convert to honest-ENOSYS
cheaply so a `sigsuspend()` call degrades to a soft error instead of taking down the unikernel.
`getrandom`/`GRND_NONBLOCK` and `dlvsym` are low: both are soft, narrow, and correct enough to
ship with a one-line fix or a documented caveat respectively.
