# OSv next tasks, queued 2026-10-16 (operator-approved)

Copyright (c) 2026 Greg Burd. BSD-3-Clause.

Added after the lwext4 fork review and roadmap audit. Each is a task to pick up in a future
session. The locale goal (Stages 0-4) is done and open upstream; these are the next batch.

## lwext4 follow-ups (from the fork review)

- **L1. #1533 patch 0002 (small, safe).** Carry the vetted Aladdin-R-D subset as
  modules/lwext4/patches/0002-*.patch, credited: 2f5714d42 (bitmap OOB write, the standout, fix
  error codes to EIO), 1d32b2f17 (dir NULL guard), fa299459e (mkfs div-by-zero, EINVAL). Add as a
  second commit on #1533. SKIP 1a58d2275 (redundant with #1533), the marginal NULL guards, and
  especially ae525c386 (unsafe double-free "fix", risks UAF). Full analysis:
  .local/LWEXT4-FORK-REVIEW-AND-ROADMAP-2026-10-16.md.
- **L2. Curate antimatter-studios fixes (focused task).** Cherry-pick the antimatter correctness
  fixes relevant to OUR usage - extent/dir/symlink/xattr and the multithread locks - as reviewed
  patches on our osvunikernel pin, each credited, each with its red/green test lifted from
  antimatter. Do NOT swap the base yet (2.5-week-old solo fork). Full analysis:
  .local/ANTIMATTER-LWEXT4-EVAL-2026-10-16.md.
- **L3. Upstream note to Chris Thomas** (author of both antimatter-studios/lwext4 and gkostka
  PRs #107/#111): reference our #1533/#1449, that OSv consumes lwext4, and our needs
  (crafted-image robustness, single-glibc-ABI musl build, a journaling toggle). Low effort.

## Four stub/gap AUDITS requested by the operator (audit impact, then decide)

Each task: audit which real workloads hit the gap, the severity, and the fix size; then decide
fix vs leave-with-a-clear-error vs document. Do not just patch blindly.

- **T1. fcntl + faccessat locking/access gaps.** fcntl F_SETLK / F_GETLK / F_SETLKW / F_SETOWN are
  stubbed (fs/vfs/main.cc:1908-1917, WARN_ONCE); faccessat(AT_SYMLINK_NOFOLLOW) is UNIMPLEMENTED
  (:1977). #1530 already improves F_GETLK (reads args by command, reports no conflict) - fold that
  in. Who needs real advisory locking on OSv? PostgreSQL uses it for the postmaster lock file;
  measure whether the stub causes silent corruption (two postmasters) or is benign on a single
  unikernel instance. Decide: real whole-file advisory locks, or a documented single-instance
  assumption.

- **T2. ext4 D2.1 + D2.2 (the real FS work).** D2.1 journaling: our build disables it
  (osvunikernel 6f6d8f7c5 "Disable journaling") and libext does not wire it (ext_vnops.cc:19).
  Adopting antimatter (L2/future re-pin) hardens the journal code but the OSv-side wiring
  (enable JBD, journal_start/stop around writes, recovery on mount, config toggle, fsync
  semantics) is still ours. D2.2 write perf: block allocation is "a rather very naive
  implementation which eagerly allocates" (ext_vnops.cc:1390); no zero-copy pagecache bridge
  (:1953, "can come later if it shows up hot") - reuse the ZFS ARC pagecache bridge. Audit:
  does any target workload need ext4 write durability/perf, or is ext4 mainly a read/boot-image
  path with ZFS carrying the write workload? That answer sizes D2.1/D2.2.

- **T3. libc stub cluster.** sigsuspend UNIMPL (libc/signal.cc:249); _pthread_cleanup_push/pop are
  no-op stubs (libc/pthread.cc:1264-5); dlvsym stubbed, ignores the version (libc/dlfcn.cc:90);
  GRND_NONBLOCK not honored by getrandom (libc/random.c). Audit which are reachable by real
  programs: _pthread_cleanup_* as no-ops silently skip cleanup handlers on thread cancel/exit -
  a correctness hazard if any app relies on them; sigsuspend is used by signal-driven code;
  dlvsym/GRND_NONBLOCK are narrower. Decide fix vs honest ENOSYS vs document.

- **T4. io_uring + driver "not implemented" branches.** io_uring multishot variants and SQE128
  ring geometry are honest rejections (core/io_uring.cc:781,1531,3065); NVMe PRP list >1 page not
  implemented (drivers/nvme.cc:171); nvme-queue.cc:315 and scsi-common.cc:238 (REPORT LUNS)
  "not implemented". Audit: do our workloads (PG async IO, large IOs) hit the NVMe >1-page PRP
  limit? That one could be a real IO-size ceiling. The io_uring rejections are ABI-honest and
  low priority unless an app needs multishot. Decide per branch.

## Standing context
- EC2: profile `kiwi` was replaced 2026-10-16 with a NEW account (same name). Before any launch,
  re-auth with `aws sts get-caller-identity`, verify/recreate keypair + SG, re-check quota.
- Still open from the roadmap, unchanged: B1 Azure/Hyper-V, B3 true hot-plug, B4 GPU/accelerators,
  D4 RDMA/DPDK/AF_XDP, E1 security audit (last). PG scaling cliff + idle wedge NOT root-caused.
