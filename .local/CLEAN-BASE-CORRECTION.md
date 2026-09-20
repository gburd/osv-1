# My "clean base" was wrong, and the real fix is one cherry-pick

2026-09-06. The p99 agent stopped the line correctly and the error was mine.

## What I got wrong

I built `wip/pg-clean-base` = `upstream/master` + PR #1456 and called it the clean
benchmark base. It cannot run PostgreSQL at all.

Verified myself, in the source:

| branch | `setsid()` in runtime.cc |
|---|---|
| upstream/master | `WARN_STUBBED(); return -1;` |
| wip/pg-clean-base (mine) | `WARN_STUBBED(); return -1;` |
| wip/pg-zfs-bench-v26 (serves PG) | returns a non-negative session id, with a comment saying it does so **because returning -1 makes PostgreSQL treat session creation as FATAL** |

The agent's measured evidence on my base:
- on ZFS: `Aborted`, backtrace `fork+90 -> page_fault -> mmu::vm_fault+1179 ->
  osv::handle_mmap_fault`
- on ramfs: `setsid() stubbed` -> `FATAL: setsid() failed: operating system
  error 0` -> `FATAL: could not close postmaster death monitoring pipe in child
  process: EBADF` -> `page fault outside application` at `fdclose(int)+24`

Scale of my mistake: **v26 has 129 commits my base lacked** - the whole cross-AS
coherence series (POSIX-shm/DSM, net-RX, epoll, PLT bind-now, ZFS taskq/kmem
identity-heap routing) plus small but load-bearing shims like `setsid()`. PR #1456
is necessary but nowhere near sufficient. My base was clean of everything,
including the parts that make it work.

## The fuller merge is also not the answer (yet)

`v26 + upstream/master` produces **22 conflicts**, including `.gitignore` (which I
must not modify) and the entire `modules/open_zfs/` layout collision our own audit
predicted (our patch-series layout vs master's in-tree layout). That is a real
porting project, not a benchmark prerequisite.

## The actual fix: one cherry-pick

`ae077860c` cherry-picks **cleanly** onto v26. One file, 19 insertions, no
conflicts.

    branch wip/pg-v26-virtioblk @ 9b3207e5c
    = wip/pg-zfs-bench-v26 + cherry-pick ae077860c

Verified in the source, not just the commit graph:
- `blk::req_done()` now explicitly does NOT take `_queue_locks[q]`, with the
  deadlock reasoning documented (producer sleeps in `add_buf_wait` holding the lock
  while the completion thread needs it to drain)
- `setsid()` still returns success, so PostgreSQL still starts

So the base is BOTH able to run PostgreSQL AND free of the 19-second stall. That is
all the p99 measurement needed. The sweep is proceeding on it.

## Byproduct worth chasing: PR #1494 may target a symptom

The agent found that passing `open_zfs` explicitly in the image list registers
`provides=['zfs']` and **shadows `modules/zfs/module.py`**, dropping the
`/usr/lib/fs/libsolaris.so` manifest line - and that
`image=zfs,zfs-tools,postgres18-musl` builds clean with no manual `.so` pre-build.

That means the MKBOOTFS failure we have been working around for months (and which
PR #1494 addresses by changing `bootfs_dep`) may have a different root cause: a
module-shadowing bug in the image list, not a missing Makefile dependency. #1494
still looks correct on its own terms (the manifest names libsolaris.so
unconditionally, so it should be a prerequisite), but I want the agent's precise
finding before claiming #1494 is the right fix. Do not close or amend #1494 yet -
verify first.

## Lesson

Third topology error in this program, and the most expensive: I defined a base by
what I wanted it to CONTAIN (the virtio-blk fix) without checking what it would
LOSE. Before declaring any base usable, verify it can still do the job - here, one
`grep setsid runtime.cc` would have caught it in seconds. "Does it build" is not
"does it work".
