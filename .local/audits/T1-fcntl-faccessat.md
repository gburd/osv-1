# T1 — fcntl POSIX locks & faccessat AT_SYMLINK_NOFOLLOW: impact audit

Copyright (c) 2026 Greg Burd. BSD-3-Clause.

Read-only audit on `master` (authoritative upstream state). Line citations are `master`
unless marked otherwise. `UNIMPLEMENTED` = `WARN(...)` then **`abort()`**
(`include/osv/stubbing.hh:41`): a hard crash (SIGABRT), not ENOSYS, not a no-op.

## (a) Exact current behavior per stub

### fcntl POSIX locks — `fs/vfs/main.cc:1851` (`int fcntl(int fd, int cmd, int arg)`)

| cmd | master behavior | effect for caller |
|-----|-----------------|-------------------|
| `F_SETLK`  (1907) | `WARN_ONCE("...stubbed")`, `break` → `ret=0` | **succeeds silently as no-op**: lock "granted", nothing stored |
| `F_SETLKW` (1913) | same | same — never blocks |
| `F_GETLK`  (1910) | `WARN_ONCE`, `break` → `ret=0`, **`lock->l_type` left untouched** | returns 0 but does NOT set `l_type=F_UNLCK`; caller reads uninitialized `l_type` |
| `F_SETOWN` (1916) | `WARN_ONCE`, `break` → `ret=0` | no-op success (no SIGIO/SIGURG owner wiring exists anyway) |

Two separate defects: (1) the locks are **unenforced no-ops that report success** —
dangerous *only* if two independent lock-holders compete (see (b)); (2) on `master`
the third arg is declared `int arg`, so `fcntl(fd, F_GETLK, &flock)` reads a `struct
flock*` **as an int** — truncation/UB on LP64. F_GETLK also never writes `l_type`, so a
caller that trusts the result sees garbage.

**PR #1530 (`41124a8fd`, branch `pr/fcntl-varargs`; NOT in `master`, NOT in the current
working branch) fixes defect (2) only:** makes `fcntl` variadic and reads the arg by
command (`struct flock*` for the lock cmds), fixes the tracepoint, adds `tst-fcntl.cc`
cases. It does **NOT** make F_GETLK report no-conflict — the F_GETLK/F_SETLK/F_SETLKW
cases are still `WARN_ONCE; break`. The task brief's "already improves F_GETLK /
report no conflict" overstates the landed diff; #1530 only stops the pointer being
mangled. So after #1530, F_GETLK still leaves `l_type` unset.

### faccessat — `fs/vfs/main.cc:1974`

```
if (flags & AT_SYMLINK_NOFOLLOW)
    UNIMPLEMENTED("faccessat() with AT_SYMLINK_NOFOLLOW");   // -> abort(), crashes
```
Only `AT_SYMLINK_NOFOLLOW` trips it. `AT_EACCESS` is **not** checked, so it silently
falls through to `access()` (effective-vs-real uid is moot on OSv anyway). Any other
flags path and all of `access()`/`euidaccess()`/`eaccess()` just call `access()`.

## (b) Severity

### PostgreSQL on a single OSv instance — BENIGN (verified, not assumed)

- PG's two-postmasters-on-one-datadir guard is `CreateLockFile()` using
  `open(O_RDWR|O_CREAT|O_EXCL)` + a PID file, **not** fcntl locks
  (`apps/postgres/multithreaded-postgres/src/backend/utils/init/miscinit.c:1262,1267`).
- `grep -rE 'F_SETLK|struct flock' src` across the in-tree PG source returns **zero
  hits**. PG does not take fcntl advisory locks at all here. The stubbed locks are
  therefore never called by PG; no data-corruption path exists through them.
- OSv is single-process (`fork`/`vfork`/`execve` are stubs: `execve` →
  `libc_error(ENOEXEC)` without `CONF_fork`, `execvp` is `NO_SYS`→ENOSYS,
  `runtime.cc:214/221`). There is no second competing process to race the no-op lock,
  so even for a non-PG caller the classic "two writers both think they hold it" hazard
  needs two cooperating threads *inside one app* relying on POSIX fcntl locks for
  intra-process mutual exclusion — rare and self-inflicted. The dangerous no-op-success
  is latent, not reachable on the PG path.

### faccessat AT_SYMLINK_NOFOLLOW — crash, but narrow reach

- Reachability: musl `access()` and the no-flag `faccessat()` fast path both pass
  `flag=0` (`musl/src/unistd/access.c:10`, `faccessat.c:21`), so the overwhelmingly
  common libc path **never** hits the abort. Only an explicit
  `faccessat(dirfd, path, mode, AT_SYMLINK_NOFOLLOW)` does. The in-tree test
  `tests/tst-faccessat.cc` only passes `flags=0/F_OK` — the abort path has **no test
  coverage**.
- Severity when hit: `abort()` = whole-unikernel crash, not a recoverable `-1/EINVAL`.
  An app probing a symlink without following it (some package managers, `coreutils`,
  Rust/Go std `access`-with-nofollow helpers) would kill the VM instead of getting an
  errno it can handle. Higher blast radius per call than the lock stubs, lower
  reachability. No current OSv in-tree consumer found.

## (c) Recommendations

### 1. fcntl POSIX locks → **honest-error-only (minimal), after landing #1530 first**

Reasoning: a *real* whole-file advisory-lock implementation (per-vnode lock list,
range/overlap merge, F_RDLCK/F_WRLCK conflict rules, F_SETLKW blocking + wakeup, owner
cleanup on close) is a few hundred lines plus a vnode field and tests — real value only
appears with multiple competing processes, which OSv does not have. Not worth it now.

Do the small honest fix instead (on top of #1530's correct arg reading, ~15–25 lines):
- **F_GETLK:** set `lock->l_type = F_UNLCK` before returning 0 — the honest "no
  conflict on a single-process system" answer, and it stops callers reading
  uninitialized `l_type`. This is the piece the brief *attributed* to #1530 but which is
  not actually there; it still needs doing.
- **F_SETLK / F_SETLKW:** keep returning success (correct for single-process: the lock
  can never conflict), but demote the WARN to a one-line comment stating the
  single-process assumption so it is a documented contract, not a silent stub.
- Land **#1530 first** — without it the pointer is still read as `int` and any honest
  F_GETLK write would scribble through a truncated pointer.

### 2. faccessat AT_SYMLINK_NOFOLLOW → **real-fix (small, ~10–15 lines)**

Reasoning: cheap, removes a crash, and the lstat primitive already exists. Replace the
`abort()` with a `lstat`-based check: resolve relative to `dirfd` (reuse the
`vfs_fun_at2` resolver already used two lines below), `lstat()` the final path, and apply
the `mode` bits against the link's own `st_mode` rather than following it. If honoring
the flag fully is deemed out of scope, at minimum convert the `abort()` to
`errno=EINVAL; return -1` so a mis-probe cannot crash the VM — but the lstat version is
only marginally larger and is correct, so prefer it. Add an `AT_SYMLINK_NOFOLLOW` case to
`tests/tst-faccessat.cc` (currently absent) with a real symlink, red-before/green-after.

### Priority

faccessat first (removes an abort for ~15 lines, has a negative test gap to close), then
the F_GETLK honesty patch stacked on #1530. Neither blocks PostgreSQL, which touches
neither path.
