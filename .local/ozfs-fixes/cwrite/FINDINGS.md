# OSv+PostgreSQL concurrent-write wedge (c>=8 RW) -- root cause + fix

Box: i-06d76590dc0df1341  (m5d.metal, us-east-2, 96 vCPU, 4x838G LOCAL NVMe, tag osv-cwrite)
Base: #1458 integ/pg-fork-zfs tip 861be4908 (default mmap, ZFS-on-local-NVMe, conf_fork=1)
Fix tip: 6f8f0e3c8  (bundle .local/ozfs-fixes/cwrite/cwrite-corruptor-fix.bundle, base 861be4908)

## Symptom (reproduced, matches the DEFINITIVE local-NVMe A/B)
- pgbench c1 RW baseline: 1173 tps, 0 failed (task's ~1291; single-writer path fine).
- pgbench c8 RW at -smp 48 / -smp 16: after 2-3 runs the guest starts returning
  `could not read/write blocks ... EIO`, `page verification failed, calculated
  checksum X but expected Y` (PG's OWN 8K page checksum -- data_checksums=on in
  PG18), and `invalid page`, clustered on ~128 KiB-ALIGNED block runs (16 x 8K).
  On the first repro run (run2, -smp 48) it took an outright page-fault Aborted in
  a forked backend AS.  Postmaster stayed up; `select 1` still answered.

## What it actually is (NOT primarily a lost-wakeup -- the page-UAF corruptor class)
The task framed the headline as a lost-wakeup, but on committed 861be4908 the
DOMINANT, reproducible c>=8 RW failure is the page-pool cross-CPU reclaim
use-after-free (the ROADMAP "corruptor #1/#2" class), surfacing as three faces
of ONE bug (hang / crash / EIO+page-checksum), depending on which recycled page
the stale store lands in.  The hang, the abort, and the EIO are the same
cross-AS/cross-CPU page reclaim hazard; the EIO/page-checksum face reproduces
most readily on local NVMe under -smp 16/48.

### The COW-incoherent / cross-CPU-incoherent structure (named)
The OSv small-object pool's lock-free MPSC cross-CPU garbage queue
(lockfree::unordered_queue_mpsc in core/mempool.cc) links freed objects through
an intrusive `free_object::next` pointer stored INSIDE the object's backing page:
  push():  item->next = _head; CAS(_head, item)   // 8-byte store into the page
  pop():   _poll_list = r->next                    // consumer look-ahead
free_same_cpu() (corruptor #1) and free_page() (corruptor #2, the page/L1 path)
could return a backing page to page_pool while a producer on another CPU was
still mid-push (its item->next store in flight) OR the consumer's _poll_list
look-ahead still dereferenced an object in that page.  page_pool immediately
recycles the page into a live 4096B object -- a ZFS abd read-chunk / range_tree
btree leaf / a forked backend's PG heap page (in the shared-anon mmap region) --
and the stale 8-byte next-link store lands INTO that live object.  The victim is
seen later, never the writer:
  * PG heap page clobbered -> PG page-checksum mismatch ("page verification failed")
  * ZFS block clobbered     -> ZFS checksum EIO ("could not read blocks")
  * thread TLS slot clobbered -> preemptable()/migrate_disable page-fault (the Aborted)
The ~128 KiB alignment = SPA_OLD_MAXBLOCKSIZE (ZFS max record / large-alloc unit).

### Why c1 works but c>=8 wedges
c1 never frees cross-CPU under concurrent producers, so the MPSC drain window is
never open while a page is reclaimed.  c>=8 RW drives many concurrent
free/alloc across CPUs (WAL, buffer eviction, ZFS abd churn), opening the window.

### Why it was present on 861be4908
The two fixes existed on the abandoned corruptor-fix-f2b branch (14667a8d,
6ccf4a92) but were NEVER carried onto the re-organized #1458 fork stack.
`git diff <base> 861be4908 -- core/mempool.cc` shows ZERO of the fix content
(max_retained_empty / PGQUAR_DEPTH / flush_empty_pages) -- the S1..S6 restructure
dropped them.  This is why the DEFINITIVE A/B (also on 861be4908) wedged at c8.

## The fix (2 commits, both #if CONF_fork, conf_fork=0 byte-identical)
1. "keep cross-CPU pool-page reclaim off the lock-free garbage path" (mempool.cc
   +89, mempool.hh +21): never return an emptied pool page to page_pool from
   free_same_cpu; keep it fully-free on the per-CPU _free list; release surplus
   empties (>max_retained_empty=4) back to page_pool only from collect_garbage,
   AFTER every incoming garbage sink is drained (single-consumer preempt-locked
   quiescent point -- no MPSC link references any pool object there).
2. "quarantine page-pool reclaim to close the page-path free_object UAF"
   (mempool.cc +60): the page/L1 sibling.  free_page() parks a freed page in a
   bounded per-CPU ring (PGQUAR_DEPTH=512, 2 MiB/CPU) and recycles only the
   oldest after 512 subsequent frees, so any in-flight MPSC next-link store
   drains onto a not-yet-live page.  Bounded so a free storm cannot OOM.

## Validation (all on the fix tip 6f8f0e3c8, -smp 48, 32G, default mmap, ZFS-on-NVMe)
PASTED pgbench RW (0-failed everywhere; A=Aborted E=EIO PV=page-verification counts):
  c8  x8 runs: all 0 failed (tps 4953/4766/3702/2698/2857/2679/2882/2893)  A=0 E=0 PV=0
  c8  -T60 sustained: 154029 tx, 0 failed, 2643 tps                         A=0 E=0 PV=0
  c16: 51191 processed, 0 failed, 3137 tps                                  A=0 E=0 PV=0
  c32: 7497 processed, 0 failed, 610 tps                                    A=0 E=0 PV=0
  c48: 3426 processed, 0 failed, 415 tps                                    A=0 E=0 PV=0
  c64: 2347 processed, 0 failed, 432 tps                                    A=0 E=0 PV=0
  (c48/c64 needed a generous PGCONNECT_TIMEOUT: the connection-storm ramp is the
   separate RO/scheduler concurrency ceiling [BLOCKER 1], not a write wedge; the
   guest stayed clean + serving throughout.)
Pre-fix, the SAME -smp 48/-smp 16 c8 runs hit EIO by run 2-3 and accumulated
(E=14 -> 29 -> 41 -> 52 ...); post-fix ZERO across every level.

REBOOT + WAL RECOVERY (was poisoned pre-fix):
  redo starts 0/5E0D1F28 -> redo done 5.62s -> end-of-recovery checkpoint
  (129696 buffers) -> ready to accept connections
  full-table read after reboot: count=10,000,000  sum(abalance)=1470725  (clean,
  no EIO -- no on-disk poisoning).

The tps DROP at high concurrency is BLOCKER 1 (the RO/scheduler wake-round-trip
ceiling, a separate effort); this fix removes the WRITE wedge/corruptor
(BLOCKER 2) so concurrent writes complete correctly at every level.

BOOT: the fixed image boots to "database system is ready to accept connections"
reliably on a CLEANLY-EXPORTED pool (observed READY at ~2s on every clean-pool
boot across the fix validation).  A crash seen while boot-count-testing was in
zfs_mount / zfs_mount_at / sys_mount (ZIL replay), reproduced ONLY on a pool left
dirty by kill -9'ing a serving guest without a clean export -- the known
POOL-STATE-dependent ZFS mount fault ([#1423/OpenZFS], untouched by this fix, in
the ZFS mount path not the allocator).  It is not a regression from this change
(core/mempool.cc only) and not the concurrent-write corruptor.

## Deliverable
- Commits on #1458 integ/pg-fork-zfs, base 861be4908, tip 6f8f0e3c8, author
  Greg Burd, [fork-stack / CONF_fork], leak-clean, no em-dashes, conf_fork=0
  byte-identical, Rule-1b clean (0 sigtimedwait/signal reverts).
- Bundle: .local/ozfs-fixes/cwrite/cwrite-corruptor-fix.bundle
  (git fetch it, then it applies on 861be4908; re-sign + push to #1458).
- Commits are UNSIGNED (built via cherry-pick with --no-gpg-sign on the builder);
  re-sign (G) before pushing.
