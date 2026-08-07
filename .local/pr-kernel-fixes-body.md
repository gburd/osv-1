A batch of independent kernel- and block-layer changes found while running the ZFS and Crucible workloads. This branch bases directly on current `master` (3df7df76). Five commits, grouped below.

### Block layer

- **block: TRIM/DISCARD support and multiqueue I/O** (f9903dc9).
  - `BIO_DISCARD`: a new block-layer request type plumbed into virtio-blk's request descriptor (`VIRTIO_BLK_T_DISCARD`). Maps to ZFS's `ZIO_TYPE_TRIM` and to Crucible's protocol-level discard. Drivers without discard support return ENOTSUP; the caller falls back to overwrite-with-zero.
  - Multiqueue: per-CPU queue dispatch in virtio-blk so a multi-vCPU guest submits I/O on multiple queues concurrently. Adds a `scripts/run.py` helper wiring QEMU's `num-queues`, a per-queue completion-notifier locking-race fix (the lock was released too early under preemption), and a `device_delete_child` return-type fix surfaced while threading the multi-queue teardown path.

### Async I/O

- **fs: implement io_uring async I/O interface** (df0962ed).
  io_uring(7) implementation backed by OSv's existing async-I/O plumbing. Supported opcodes: READ, WRITE, FSYNC, NOP, OPENAT, CLOSE, READV, WRITEV, POLL_ADD, POLL_REMOVE, TIMEOUT, ACCEPT, CONNECT, RECV, SEND. Submission/completion queues mmap'd into user memory; SQE/CQE layout matches the Linux 5.15 ABI. `io_uring_setup`/`enter`/`register` syscalls; SQ poll thread (`IORING_SETUP_SQPOLL`); linked SQEs (`IOSQE_IO_LINK`) and drain barriers (`IOSQE_IO_DRAIN`). `tst-io_uring.cc` covers each opcode, link semantics, drain ordering, and SQ-poll. Note: OSv's io_uring is not used by OpenJDK 21 virtual threads (JDK 21 still routes through epoll); native code can use it.

### Kernel correctness

- **net: harden TCP net-channel fast path against connection teardown** (f96d88fe).
  `tcp_net_channel_packet()` assumed SOCK_LOCK held and the inpcb still attached. Under connection churn a queued packet can be drained after `in_pcbdetach()` cleared `inp_socket`, or from the IRQ classifier path without SOCK_LOCK, and a packet can arrive after the tcpcb moved to CLOSED/TIME_WAIT -- tripping `tcp_do_segment()`'s state KASSERT and panicking. Re-resolve the socket in the callback and drop the packet if detached; acquire SOCK_LOCK if not already held (OSv's recursive mutex makes re-locking a cheap depth bump); skip segments for connections at/below LISTEN or in TIME_WAIT, matching the slow path. This fix is load-bearing for the Crucible driver's sustained network I/O.

- **synch: fix wakeup_one to honor empty equal_range result** (f5a8ac54).
  `wakeup_one()` tested the equal_range lower bound against `_evlist.end()`. When the channel is absent, equal_range returns an empty range whose first iterator points at the next-larger key, not `end()`, so the old guard woke an unrelated waiter and erased its node while leaving the intended sleeper stranded. Test `first != second`.

- **elf: include path and sizes in "executable too short" error** (7a82addf).
  Report pathname, actual file size, and required length on a short ELF read so a truncated or mis-pathed binary is diagnosable.

### Verification

Kernel compiles and links clean on GCC 14.3 / Boost 1.87 (`./scripts/build image=empty`, fresh loader.elf, RC=0).
