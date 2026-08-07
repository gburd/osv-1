# MMAP c32 RO lock-contention profile — THE DELIVERABLE (beef acct 840154381708, us-east-2)

## Instance
- instance-id: i-018d8d7d05b47257c  (m5d.metal, us-east-2, real bare-metal KVM /dev/kvm, NOT TCG)
- 96 vCPU, 377 GB RAM, 4x 838GB local NVMe + 120G EBS root.
- Built OSv+PG at 6b71c76385 (image=zfs-tools,pg18-fork fs=zfs conf_zfs=openzfs conf_fork=1)
  + lockprof patch (lockprof=1), *** DEFAULT mmap (NO shared_memory_type=sysv) ***.
- Harness: tap0+vhost single-queue on br0, driven over the tap IP 192.168.100.2 (NOT loopback,
  proven: inet_server_addr = 192.168.100.2). qemu real KVM (-accel kvm -cpu host), smp32, 64G.

## RESULT 1 — instance-id
i-018d8d7d05b47257c

## RESULT 2 — does mmap survive concurrent c8 forks?  =  YES
8 concurrent connections each forked a backend + touched shared_buffers
(select count from generate_series 1..100000). ALL 8 returned 100000, ZERO crash,
NO Aborted/panic/Assertion in the OSv console. The DECIDER's claim holds: DEFAULT
mmap survives concurrent forks at smp>1 (the prior smp>1 fork crash was SYSV-specific).
Single-conn select 1 -> 1 confirmed first; postmaster ready in 3s.

## RESULT 3 — THE c32-mmap HOT-LOCK VERDICT (the deliverable)
c32 RO sustained load (pgbench -S -c 32 -j 8 -T 60 over the tap):
  tps = 20371.8, latency avg = 1.571 ms, 1,114,566 txns, 0 failed.
  (matches the OSv-side wall: c32 ~20k, machine ~90% idle — serialization-bound, NOT storage.)

LOCKPROF DELTA over the c32-RO window (first post-load snapshot -> last, isolating the RO load
from the boot/fork noise):

  site            Δcalls       Δblocked   Δwait_ns      share-of-window
  registry_shard  2,586,624    5,009      2.522 s       ~73%   <== HOT LOCK
  vmas_write         11,029       15      0.944 s       ~27%   (few very-long COW holds)
  vmas_read          16,357        2      ~40 us        0%
  page_ranges         1,191        1      ~2 us         0%

Cumulative-since-boot (for reference, includes the c8 fork storm):
  registry_shard  calls=3,004,416  blocked=5,094  wait_ns=2.542 s  (46%)
  vmas_write      calls=41,922     blocked=49     wait_ns=2.788 s  (50%)
  vmas_read       calls=29,292     blocked=5      wait_ns=0.0006 s (0%)
  page_ranges     calls=7,502      blocked=716    wait_ns=0.142 s  (2%)

*** VERDICT: the hot serialization point under DEFAULT mmap at c32 RO is
    CANDIDATE (2) — the shared_anon_page_provider registry lock (reg->lock / registry_shard). ***

WHY this is the answer to THE ONE QUESTION (and why the prior sysv profile was invalid):
- Under sysv the registry was 0 calls ALWAYS (shared_buffers bypassed the page-provider via
  SysV shm). Under the CORRECT mmap config the registry is squarely ON the fault hot path:
  2.59 MILLION calls during the 60s RO window (0 -> 2.59M is the whole difference).
- It is the top CONTENDED lock: 5,009 blocked acquisitions / 2.52s blocked-wait during the RO
  window = ~73% of the window's total blocked-wait. This is REAL lock contention, so the answer
  is (2) the registry lock, NOT (4) the wake-dispatch path. The machine is not merely
  idle-serial on a non-lock wake round-trip; there is a measurably contended mutex, and it is
  the 256-way-sharded shared-anon registry (sh.lock in mmu.cc get_shared_anon_page, sharded by
  80a5bf863). At c32 the 256-way shard is NOT enough — 5k blocks in 60s.
- vmas_write is 2nd (~27% of the window, only 15 blocks = a handful of very-long COW-write-fault
  holds on first-touch of the 8GB shared_buffers under fork COW). Real but low-frequency; the
  registry is the higher-frequency, higher-block-count wall for a RO workload.

## LEVER for the NEXT (fix) agent — do NOT implement here
The registry lock (reg->lock / per-shard sh.lock) is the named wall under mmap. Upgrade paths to
try (next agent): (a) more shards / finer registry sharding beyond 256; (b) an RCU/lock-free
lookup for the fast path (the fast path is a find(va) under the shard lock — 2.59M calls/60s, the
lookups dominate, only 5k of them block, so a read-mostly lock-free/ RCU map should shed most of
the 2.52s); (c) per-CPU registry caching of recently-faulted va->page. The a-priori "registry
sharding is a DEAD END" note was TRUE for the sysv config only; under mmap the registry IS the
hot lock and further de-serializing it IS the lever. Measure an A/B (registry lock-free vs stock)
at c1..c64 RO on this same substrate.

## Cleanup
- box i-018d8d7d05b47257c: TERMINATED (see confirmation below).
- qemu + docker containers reaped.

## Profiler note
- lockprof.hh/cc + lockprof.patch build cleanly at 6b71c76385 with lockprof=1; loader.elf carries
  the [LOCKPROF] dumper strings + start_dumper/site_name/counters symbols (verified). Default
  build (lockprof unset) byte-identical. Dumper prints every 3s via console::write.
- Substrate build recipe (turnkey, DEFAULT mmap): .local/ec2-assets/build-cache/ adapted +
  /tmp/osv-stage/nvme-fixes/{host-build.sh,kvm-seed-profile.sh} (staged tree at 6b71c76385 +
  lockprof, submodules pre-populated, fedora:39 privileged /dev/kvm build container, KVM boot,
  tap0+vhost, DEFAULT mmap PGARGS with NO shared_memory_type=sysv).
