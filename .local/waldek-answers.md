# Answers to Waldek's review comments on #1399

## Structural: split into 5 PRs
The 5 commits each sat directly on master, so I split them into one PR per
subsystem as requested:
- block: TRIM/DISCARD + multiqueue (discard and MQ kept together per your note
  that they touch the same code and can share a PR)
- io_uring
- net: TCP net-channel teardown hardening
- synch: wakeup_one empty-range fix
- elf: "executable too short" error detail

lzloader .rodata change moved to its own small PR (it was unrelated — see below).

---

## docs/block-discard.md:1 — "split into 2 commits, same PR"
Done. The block PR now reads as discard + multiqueue. I kept them in a single
PR since they touch the same regions of virtio-blk.cc, but the docs and the
change are organized so each concern is independently reviewable.

## bsd/porting/bus.h:110 — "Is this related?"
No — it was unrelated. `device_delete_child()` returns `int` but had
`return NULL;`; virtio-blk never calls it (its destructor is a no-op TODO).
The only in-tree caller is xenbusb.cc. I removed the hunk from the block commit
entirely. The commit message no longer mentions a device_delete_child fix.

## drivers/blk-mq.cc:14,20,58 — C API? locking? comments?
These were dead code. `blk-mq.cc`/`blk_mq.h` were not referenced by any driver,
test, or app, and `read()/write()` already benefit from the multiqueue support
purely via virtio-blk.cc (queue selected by submitting CPU). There was no app
or driver consumer of blk_mq_*; it was speculative scaffolding. I deleted the
module and its Makefile entry rather than document/lock an unused API. If a
future driver needs a generic MQ layer we can add it then, against a real
consumer.

## drivers/virtio-blk.cc:147 / :325 — single interrupt, cpu0 drains all
You are right, and nvme.cc's `driver::register_io_interrupt()` is the better
model. The current driver wires a single interrupt: cpu0's completion thread is
woken and drains every queue under each queue's lock, while queues 1..N poll
their own ring. The submission path already scales (each CPU uses its own ring,
own lock; two CPUs on different queues never block each other). Only completion
is centralized. I documented this honestly in block-multiqueue.md, including the
known limitation and the per-queue-interrupt path (as nvme does) as the future
enhancement that lets each queue's completions land on its owning CPU and drops
the cross-queue drain loop. I did not claim a lock-less design.

## drivers/virtio-blk.cc:367 — "lock because we may race with req_done()?"
Yes. `make_request()` holds `_queue_locks[qid]` because cpu0's `req_done()`
drain-all loop and the qid>0 poll loop both call `drain_queue()` on that same
ring. The per-queue lock serializes submission against completion on each ring.

## arch/x64/lzloader.ld:13 — "unrelated change"
Correct, unrelated. Moved to its own PR (lzloader: give .rodata its own output
section). It is not part of the io_uring change.

## include/api/x64/bits/syscall.h:647 — "why not aarch64?"
aarch64 already defines these — see include/api/aarch64/bits/syscall.h:
`__NR_io_uring_setup/enter/register` (425/426/427) and the `SYS_*` aliases are
already present. The syscall registration (linux.cc, syscalls.cc.in) is
arch-neutral, so io_uring works on aarch64 too. The x64 syscall.h addition just
brought x64 to parity; no aarch64 change was needed.

## fs/io_uring.cc:28 — Linux-based? OSv primitives? Claude? separate PR?
Yes to all. The ABI follows Linux 5.15 (SQ/CQ ring layout, io_uring_params,
io_uring_setup/enter/register), implemented on OSv primitives (sched::thread,
mutex, condvar; submissions run on the existing async I/O path). Yes, Claude
did most of the implementation, reviewed and tested against the ring ABI. It is
standalone (3 syscalls, nothing else depends on it) and is now its own PR.

## modules/zfs-tools/usr.manifest:6 — "unrelated change"
Correct. Reverted in the io_uring commit; the change is no longer present on the
io-uring branch.

## bsd/sys/netinet/tcp_input.cc:3199 — issue #936? slow-path only?
Not slow-path — it's the opposite. The change hardens the net-channel
**fast path** (`tcp_net_channel_packet`) so it mirrors what the slow path
(`tcp_input`) already does. The slow path drops segments for CLOSED/LISTEN/
TIME_WAIT connections before reaching `tcp_do_segment()`; the fast-path
callback did not, so under connection churn a packet could still be queued on
the channel after the tcpcb transitioned to CLOSED and trip the KASSERT in
`tcp_do_segment()`, panicking the kernel. Two fixes: (1) re-resolve `so` inside
the callback and bail if the inpcb was detached (`inp_socket == NULL`), since
the callback can run from the IRQ-side classifier path without SOCK_LOCK; and
(2) reject segments for `state <= TCPS_LISTEN || state == TCPS_TIME_WAIT`,
matching the slow path. The Wiki section you cite — "post_packet() pushes an
mbuf onto the net channel only if one exists" — is exactly the lifetime window
this guards: the channel outlives the socket detach. Plausibly related to #936;
I'll reference it in the PR.

## bsd/porting/synch.cc:161 — "to avoid processing empty range (ppp)?"
Exactly. `equal_range` returns `[first, second)`; an empty result has
`first == second`, but `first` is not necessarily `end()` (it points at the
first element greater than `chan`). The old `if (it != _evlist.end())` could
therefore dereference a non-matching element. The fix tests
`ppp.first != ppp.second`, matching how the range is correctly consumed
elsewhere in the file.

## tcp_input.cc:3272 / core/elf.cc:330 — "looks correct / good"
Thanks — no change.
