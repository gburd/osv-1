# PR 6 - kernel: TCP teardown, wakeup_one, ELF error-message fixes

**Branch:** `gburd/osv-1:pr/kernel-fixes` -> `cloudius-systems/osv:master`
**Base:** stacks on PR 5 (`pr/io-uring`, 85d7da40). Three-commit branch:
90995717, d5406b8b, 6e7213ae.
**Verified:** kernel compiles + links clean on GCC 14.3 / Boost 1.87
(`./scripts/build fs=rofs image=empty`, fresh loader.elf, RC=0).

---

## Title

kernel: harden TCP teardown, fix wakeup_one empty-range, ELF errors

## Body

Three independent kernel-correctness fixes found while running the ZFS
and Crucible workloads.

### Changes

- **net: harden TCP net-channel fast path against connection teardown**
  (90995717). `tcp_net_channel_packet()` assumed SOCK_LOCK held and the
  inpcb still attached. Under connection churn a queued packet can be
  drained after `in_pcbdetach()` cleared inp_socket, or from the IRQ
  classifier path without SOCK_LOCK, and a packet can arrive after the
  tcpcb moved to CLOSED/TIME_WAIT -- tripping tcp_do_segment()'s state
  KASSERT and panicking. Re-resolve the socket in the callback and drop
  the packet if detached; acquire SOCK_LOCK if not already held (OSv's
  recursive mutex makes re-locking a cheap depth bump); skip segments
  for connections at/below LISTEN or in TIME_WAIT, matching the slow
  path.

- **synch: fix wakeup_one to honor empty equal_range result**
  (d5406b8b). `wakeup_one()` tested the equal_range lower bound against
  `_evlist.end()`. When the channel is absent, equal_range returns an
  empty range whose first iterator points at the next-larger key, not
  end(), so the old guard woke an unrelated waiter and erased its node
  while leaving the intended sleeper stranded. Test `first != second`.

- **elf: include path and sizes in "executable too short" error**
  (6e7213ae). Report pathname, actual file size, and required length on
  a short ELF read so a truncated or mis-pathed binary is diagnosable.

### Notes

- Seventh in the series. The TCP fix is load-bearing for the Crucible
  driver's sustained network I/O.
