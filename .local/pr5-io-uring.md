# PR 5 - fs: implement io_uring async I/O interface

**Branch:** `gburd/osv-1:pr/io-uring` -> `cloudius-systems/osv:master`
**Base:** stacks on PR 4 (`pr/trim-multiq`, 8b15bc96). One-commit branch:
85d7da40.
**Verified:** kernel compiles + links clean on GCC 14.3 / Boost 1.87
(via the PR 6 tip). tst-io_uring (14 sub-tests) PASS on the ZFS image.

---

## Title

fs: implement io_uring(7) async I/O interface

## Body

Add an io_uring implementation backed by OSv's existing async-I/O
plumbing.

### Changes

- Supported opcodes: READ, WRITE, FSYNC, NOP, OPENAT, CLOSE, READV,
  WRITEV, POLL_ADD, POLL_REMOVE, TIMEOUT, ACCEPT, CONNECT, RECV, SEND.
- Submission/completion queues mmap'd into user memory; SQE/CQE layout
  matches the Linux 5.15 ABI.
- io_uring_setup/enter/register syscalls; SQ poll thread
  (IORING_SETUP_SQPOLL); linked SQEs (IOSQE_IO_LINK) and drain barriers
  (IOSQE_IO_DRAIN).
- tst-io_uring.cc (14 sub-tests: each opcode, link semantics, drain
  ordering, SQ-poll). Registered in modules/tests/Makefile and
  zfs-tools/usr.manifest.

### Notes

- Sixth in the series.
- OSv's io_uring is **not** used by OpenJDK 21 virtual threads (JDK 21
  still routes through epoll). Native code can use it; see the cover
  letter for the JDK-21 investigation detail.
