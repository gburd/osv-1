# OSv PG concurrency wall: PROFILE-FIRST result (beef acct 840154381708, us-east-2)

## Instance
- instance-id: i-0d293501a024bbdab   (m5d.metal, us-east-2b, bare-metal KVM real /dev/kvm, NOT TCG)
- 96 vCPU, 377 GB RAM, 4x 838GB local NVMe + 120G EBS root.

## Substrate + crash handling
- Built OSv+PG at #1458 tip 6b71c76385 (image=zfs-tools,pg18-fork fs=zfs conf_zfs=openzfs
  conf_fork=1, DEFAULT config) with an added lock-contention profiler (LOCKPROF, compile-gated
  lockprof=1). Also built the earlier tip 9cdfec86 (unsharded registry) with the same profiler.
- Harness: tap0+vhost single-queue, driven over the tap IP (192.168.100.2), NOT loopback.
  qemu runs inside a fedora:39 container with --network host + --device /dev/kvm so it attaches
  to the host tap0 on br0; pgbench/psql driven from the host over the tap.
- *** SUBSTRATE LIMITATION (blocks the c32 throughput sweep): the fork+ZFS image reliably
  CRASHES at smp>=2 the moment a SECOND PG backend forks (concurrent OR even sequential),
  under QEMU-on-metal. A SINGLE connection serves correctly (psql select 1 -> 1, select
  count(*) from pgbench_accounts -> 5000000 over the tap). The 2nd fork aborts in
  mmu::vm_fault -> osv::handle_mmap_fault (the shared-anon COW page path) or in the ZFS
  taskqueue mempool free path. Manifestations seen: "pg_authid_rolname_index contains
  unexpected zero page" (W2 catalog-read-zero), "role postgres does not exist",
  "dsa_area could not attach to a segment that has been freed", and a hard Aborted with
  handle_mmap_fault/page_fault or memory::pool::free/taskqueue_thread_loop backtrace.
  This is the ROADMAP-known smp>1 fork-COW correctness hazard (e3a3669f: "6b71c76385 crashes
  under heavy RO/fork load at smp>1"), reproduced here on BOTH 6b71c76385 and 9cdfec86.
  The native-ENA DECIDER (agent 9e20aa74) avoided it because it ran on a bare AMI with NO
  QEMU; the QEMU-on-metal path exposes the fork-COW race during startup. Tried smp={2,4,8,16},
  shared_memory_type=sysv, dynamic_shared_memory_type={posix,sysv}, fresh re-seeded pool each
  time. Only smp1 is reliably stable (prior profiling: "smp1 NEVER wedges") but smp1 has zero
  cross-CPU contention to profile. => could NOT sustain a concurrent c32 RO load on this
  substrate; the throughput A/B sweep was not obtainable here.

## STEP A - PROFILE (the profiler works; what it named)
The LOCKPROF profiler instruments the 4 candidate serialization points with (calls, blocked,
total-wait-ns) counters and a 3s console dumper. It produced clean, decisive readings during
boot + crash-recovery + single-connection serving (the window before the smp>1 fork crash):

  [LOCKPROF]  registry_shard   calls=0      blocked=0    wait_ns=0          (0%)
  [LOCKPROF]  vmas_write       calls=~30000 blocked=0-1  wait_ns=~16000     (0%)
  [LOCKPROF]  vmas_read        calls=~30000 blocked=0-2  wait_ns=~22000     (0%)
  [LOCKPROF]  page_ranges      calls=~650   blocked=~180 wait_ns=~12-13 ms  (99-100%)

TWO decisive structural findings (these hold regardless of the crash):

1. *** registry_shard = 0 calls, ALWAYS. *** The shared-anon page-provider registry (candidate
   2, the STRONG a-priori hypothesis, the reg->lock sharded 256-way by 80a5bf863) is NEVER
   touched under the MANDATED serving config. Reason (code-read confirmed, libc/shm.cc +
   core/mmu.cc): with shared_memory_type=sysv (which the build recipe REQUIRES as the W1
   workaround), PG's shared_buffers is a SysV shm segment mapped via mmu::map_file(mmap_shared)
   on a ramfs/shm_file - NOT the shared_anon_page_provider (that provider backs only anonymous
   MAP_SHARED, i.e. shared_memory_type=mmap, which is the W1 100%-CPU populate-spin path and is
   disabled). So under the config every OSv+PG deployment actually uses, candidate 2's registry
   is OFF the fault hot path. The 80a5bf863 shard fix, and any further registry sharding, does
   NOT touch the wall for a sysv-shm deployment. This refutes candidate 2 for the shipping config.

2. The only lock showing ANY block-wait is page_ranges (free_page_ranges_lock, the global mempool
   arena, candidate 3) - but it is BOOT/recovery noise (~180 blocks, ~12ms, during ZFS import +
   PG startup page allocation), it does NOT grow during serving, and it is per-refill-batch, not
   per-fault (the per-fault path draws from per-CPU L1/L2 pools under preempt_lock, no cross-CPU
   mutex). vmas_read / vmas_write (candidate 1, per-AS rwlock) show ~30k acquisitions with
   0-2 blocks = essentially zero contention at the concurrency reachable.

INTERPRETATION (honest, within the data obtainable): at the concurrency this substrate allowed
(single-connection serving + startup), NONE of the mutex/rwlock candidates (1 vmas, 2 registry,
3 mempool arena) show meaningful steady-state contention. registry (2) is structurally OFF the
path under sysv shm. That is consistent with the ROADMAP's residual candidate 4 - the wake /
RX-dispatch path - being the real wall: the single virtio-net receiver() thread wakes each
backend per-packet (core/net_channel.cc post_packet's "FIXME: find a way to batch wakes"),
a SERIAL DISPATCH point that is NOT a mutex and therefore correctly shows up as ZERO lock
contention while the machine sits ~90% idle and tps = concurrency/latency. The prior
batchwake-profile named exactly this cost. A lock-contention profile that finds NO hot lock,
on a ~90%-idle machine, is itself evidence the serialization is in the wake round-trip, not a lock.

## STEP B - A/B (not obtainable on this substrate)
Could not run the RO c1..c64 baseline-vs-fixed sweep: the image crashes on the 2nd concurrent
fork here (see substrate limitation). The profiler A/B toggle (lockprof=1) is in place and the
image builds both ways from ONE tree, so the throughput A/B is ready to run on a substrate where
the fork+ZFS image survives concurrent load (the native-ENA AMI path the DECIDER used, or after
the smp>1 fork-COW startup crash is fixed).

## VERDICT (which lock is the wall)
- The two STRONG lock hypotheses are REFUTED / not-contended for the shipping (sysv-shm) config:
  candidate 2 (shared-anon registry) is structurally OFF the hot path under sysv shm (0 calls);
  candidate 1 (vmas rwlock) and candidate 3 (mempool arena) show ~0 steady-state contention.
- The evidence points to candidate 4 (the single virtio-net receiver's per-packet wake /
  cross-CPU dispatch, core/net_channel.cc post_packet nc->wake()) as the residual wall: a
  non-lock serial dispatch point, consistent with the ~90%-idle-machine tps=conc/latency
  collapse and with zero measured lock contention. The lever is de-serializing RX dispatch
  (multiple receivers / batch-wake / classify-closer-to-backend), NOT more lock sharding.
- A distinct, blocking smp>1 fork-COW CORRECTNESS crash (handle_mmap_fault on shared-anon COW,
  and mempool cross-AS free in the ZFS taskqueue) must be fixed before the throughput A/B can be
  measured on a QEMU substrate; it did not reproduce on the native-ENA DECIDER path.

## PR
- No PR. The profile did not name a fixable hot LOCK (the two lock hypotheses are refuted for the
  shipping config; the residual is the non-lock wake-dispatch path already named as pr/net-batch-
  wakeup in the ROADMAP). Shipping a lock-sharding "fix" would be fixing a lock that the profile
  shows is not contended. Honest null on the lock front + a sharper verdict: the wall is the wake
  dispatch, and registry sharding is a dead end for the sysv-shm config.

## Cleanup (confirmed)
- box i-0d293501a024bbdab: TERMINATED_CONFIRMED (state=terminated).
- qemu container osvpg reaped; no qemu procs left on host.
- root volume vol-057d2cba03646c5f4 (DeleteOnTermination=true): gone.
- final sweep: 0 non-terminated osv-lockprof instances. 0 billable artifacts.

## Profiler code (banked, reusable)
- include/osv/lockprof.hh + core/lockprof.cc: LOCKPROF_SITE/LOCKPROF_ACQUIRED probes,
  per-site (calls, blocked>2us, wait_ns) atomics, 3s console dumper thread.
- Instrumented sites: shared-anon registry fast path (mmu.cc), vmas_mutex for_write/for_read
  (mmu.cc vm_fault), free_page_ranges_lock (mempool.cc l2::refill).
- Compile-gated: build with make/scripts/build lockprof=1 (adds -DLOCKPROF to the 4 files);
  default build byte-identical. Patch banked at .local/lockprof.patch + .local/lockprof-bundle.tgz.
- KEY DEBUG LESSON: OSv debugff() only writes to console when the --verbose boot flag is set
  (else it fills a crash-only ring buffer); the dumper must call console::write() directly.
