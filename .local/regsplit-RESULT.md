# Registry fast/insert SPLIT — c32 mmap RO (beef acct 840154381708, us-east-2)

## Instance
- instance-id: **i-04aef31bc694bd379**  (m5d.metal, us-east-2, real bare-metal KVM /dev/kvm)
- 96 vCPU, 4x 838G local NVMe. Public 3.17.190.148 / Private 172.31.17.155.
- Build: OSv+PG at 6b71c76385 base + **RCU-registry fix** (working-tree mmu.cc, reader_find
  fast path + single insert_lock) + lockprof + **REGSPLIT** counters. lockprof=1.
  image=zfs-tools,pg18-fork fs=zfs conf_zfs=openzfs conf_fork=1, **DEFAULT mmap** (NO sysv).
  Wake-steal (CONF_sched_wake_steal) EXCLUDED (kept 6b71 sched.cc) so the measurement is
  not confounded — pure registry-path build. CONF_fork=y verified. loader.elf carries
  [REGSPLIT]/[LOCKPROF] symbols.
- Harness: initdb natively under Alpine musl; ZFS pgdata pool via cpiod; boot smp32 64G over
  tap0+vhost br0, PG served at 192.168.100.2:5432 (tap IP, NOT loopback). Seed pgbench -i -s50
  (done in 6.67s). Load pgbench -S -c32 -j8 -T60.

## c32 RO run
  tps = 19684  (latency avg 1.626 ms) — matches the ~20k OSv-side wall, machine mostly idle.

## THE DELIVERABLE — registry fast/insert split (c32 RO WINDOW = FINAL - PRELOAD, isolates the 60s load)
  fast_hits            5,994,413      RCU reader_find RETURNED a page (lock-free read hit)
  fast_misses            187,475      reader_find returned null -> slow path
  insert_calls           187,475      entered WITH_LOCK(reg->insert_lock)
  insert_lost_race         2,131      double-check found it (another AS inserted first)
  insert_real            185,344      actually allocated + inserted a new page
  insert_lock_blocked      2,371      insert_lock acquisitions that BLOCKED (>2us)
  insert_lock_wait_ns 16,212,139      = 16.2 ms total blocked-wait on insert_lock over 60s

  ratio fast_hits : insert_calls = 32.0 : 1   (read-heavy, as predicted for shared_buffers)
  insert_lock blocked = 2371 / 187475 acquisitions = 1.26%, total 16.2 ms / 60s.

  Cumulative-since-boot LOCKPROF table at end of run (the WHOLE wall, all 4 sites):
    site            calls        blocked   wait_ns          share
    vmas_write      32,399       34        2,582,010,789    72%   <== HOT WALL (COW write fault)
    page_ranges     11,296       1,460       959,749,769    27%   <== 2nd (global page arena)
    registry_shard  6,234,112    446          11,864,238    0%    (RCU read path — NOT contended)
    vmas_read       27,660       6               758,584    0%
    total_blocked_wait_ns = 3,554,383,380

## THE VERDICT  ==  NEITHER read-path NOR insert-path.  The RCU fix WORKED; the wall MOVED.
- **Registry READ path is NOT the wall:** 5.99M lock-free RCU reader_find hits in the 60s
  window, and the registry_shard site shows **446 blocked / 11.86 ms (0%)** cumulative. RCU
  reads do not block — the "5009 blocked" from the prior sysv-invalid profile was the OLD
  256-way `sh.lock` fast path; the RCU rewrite eliminated it. Confirmed: reads are free.
- **Registry INSERT path is NOT the wall either:** the previously-uninstrumented insert_lock
  is now measured at **2,371 blocked / 16.2 ms over the whole 60s window** — trivial. Inserts
  are read-mostly first-touch (185k real inserts, 2.1k lost races out of 6M faults); the
  256-shards-worth of contention the ROADMAP feared on the insert side is NOT there under RCU.
- **The wall MOVED to `vmas_write` (72%, 2.58 s) — the per-AS COW write-fault path**
  (`as->vmas_mutex->for_write()` in vm_fault), with **`page_ranges` (27%, 0.96 s)** — the
  global `free_page_ranges_lock` mempool arena — second. Only 34 + 1460 blocked acquisitions
  but VERY long holds (2.58 s / 34 = ~76 ms per blocked vmas_write acquisition): a few
  backends take the AS write lock for a long time on first-touch COW faults of the 1 GB
  shared_buffers under fork, and everyone else queues behind them.

## FIX DIRECTION for the process-wide registry / fork fault path (next agent — do NOT implement here)
The registry (both read and insert) is SOLVED by the RCU rewrite — do NOT spend more effort
sharding/lock-freeing it; the split proves it is 0%/0.5% of the wall. Point the fix at the
two real walls the RCU fix exposed:
  1. **vmas_write (72%) — the AS write-lock held across COW first-touch faults.** This is the
     process-wide serialization now. Options: (a) drop the AS-wide write lock for shared-anon
     faults entirely (the shared page is resolved through the lock-free registry — a shared-anon
     write fault does NOT need the per-AS vmas write lock, it needs only to install a PTE
     pointing at the already-registered shared frame; take vmas for_read + a per-vma or
     lock-free PTE install instead of for_write); (b) range-lock / per-vma lock instead of one
     AS-wide rwlock; (c) PRE-POPULATE the shared_buffers PTEs in every fork AS at fork time so
     no write fault ever happens (AS0 registers all pages once, children map them read-once).
  2. **page_ranges (27%) — global free_page_ranges_lock in mempool l2::refill.** The
     first-touch inserts still alloc_page under the global arena lock. Per-CPU / per-node page
     staging (B2.2 pools exist!) or a batch pre-alloc for the shared-anon registry would shed it.
The a-priori "registry lock" diagnosis (ROADMAP + prior mmap-lockprof-RESULT) is now CLOSED:
under DEFAULT mmap + the RCU registry, the registry is not the wall — the COW write-fault AS
lock is. Measure an A/B (shared-anon fault takes for_read not for_write) at c1..c64 RO next.

## Cleanup
- box i-04aef31bc694bd379: **TERMINATED** — terminate-instances returned shutting-down
  (m5d.metal bare-metal teardown is slow; billing stops at shutting-down). Root EBS vol
  DeleteOnTermination=True -> auto-deletes with the instance. No other osv-regsplit instance
  in any running/pending/stopped state.
- qemu + docker containers reaped on the box before terminate.
