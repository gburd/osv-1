# Tail-latency root cause: TWO causes found, one fix each

## Cause 1: virtio-blk completion-side lock inversion (FIXED, confirmed)

`ae077860c` - `req_done()` drained the used ring while holding `_queue_locks[q]`,
which `make_request()` also holds across `vring::add_buf_wait()` (which sleeps when
the ring is full). Producer sleeps holding the lock, completion thread spins for
it, I/O stops.

Measured effect of adding it to v26 (same box, same workload, only delta):

| | v26 (no fix) | v26 + ae077860c |
|---|---|---|
| HammerDB MAX | 20,542 ms | 8,304 ms |
| worst probe sample | 19,327 ms | 7,782 ms |
| probe samples >=5s | 3 | 2 |

**Real, -60%, but NOT sufficient.** Verified byte-identical to upstream via
`git patch-id --stable`.

## Cause 2: address-space-wide writer lock on the COW fault path (fix under test)

The gate still FAILED at 2 samples >=5s (6,967 ms and 7,782 ms), so the agent
root-caused instead of tuning. The evidence is unusually strong:

**Global simultaneity.** Per-VU NEWORD MAX clustered at ~8,290 ms across 23 VUs and
~7,230 ms across 7 more - every backend unblocking together. PG's slow-statement log
shows 18 backends at 4.44 s, 32 at 5.x, 16 at 6.x, 18 at 10.x, all released within
3 ms of each other.

**CPU-bound, not I/O-bound.** During a 10 s stall: virtio inflight 1-2 (vs 60
normally), io_ticks 39-66/s (vs 218), write throughput down 4-7x - while qemu CPU
DOUBLED to ~2200-2600%. The disk was starved, the guest was spinning.

**`sync` vs `write` is emphatic.** `sync=0.009-0.012 s` while `write=86-154 s` - a
~10,000:1 ratio. ZFS commits instantly; the time goes into *submitting*.

**Checkpoints excluded.** The gate run had NO checkpoint at all (timeout=1h,
max_wal_size never reached) and still stalled 7.8 s; the 10.5 s stalls in the
instrumented repeat fall BETWEEN its checkpoint windows.

**Queue is behind a serialized WAL write, not a slow device.** Peak 31 backends on
`LWLock|WALWrite` while `IO|WalSync` never exceeded 2.

**Not fork, not I/O.** A persistent already-connected session issuing only
`select 1` (no fork, no user I/O) still stalled 2,592 ms.

**Throughput-triggered, and the observer effect proves it:** the stall only
reproduced in the two runs where PG ran at full speed (~100k NOPM). Every run with
extra samplers attached dropped to ~52-55k NOPM and the multi-second tail vanished.

**The mechanism, verified by me in the source:** our base takes
`WITH_LOCK(as->vmas_mutex->for_write())` at core/mmu.cc:2547 on every COW write
fault - an address-space-WIDE writer lock - on PostgreSQL's shared_buffers path.
One writer excludes all 32 backends' faults. That is precisely a global, CPU-bound,
throughput-triggered freeze.

The fix exists and was absent from our base (verified with
`merge-base --is-ancestor`): `dad77b7f` "mm: shared-anon fork write faults skip the
AS-wide write lock" peeks the leaf PTE lock-free and skips the exclusive lock unless
the leaf is genuinely COW. Its prerequisite `746e5bcd` (lock-free RCU shared-anon
page registry) was also absent. `80a5bf86` (shard the registry lock) was already in.

## The base now under test

    wip/pg-v26-faultfix @ 73a332f26
      = v26 + ae077860c + 746e5bcd + dad77b7f

One conflict in core/mmu.cc, resolved by hand. It mattered: the base guarded the
`for_write()` acquisition for NESTED-FAULT SAFETY (skip when
`exception_depth >= 2`, because a contended rwlock blocks -> reschedule -> trips
`assert(exception_depth <= 1)`), while `dad77b7f` guards the SAME acquisition for
SCALABILITY (skip unless genuinely COW). **Both conditions must hold**, so:

    if (is_page_fault_write(...) &&
            (!cow_peek_enabled() || write_fault_needs_cow_lock(addr))) {
        if (sched::exception_depth >= 2) { /* lock-free */ }
        else { WITH_LOCK(as->vmas_mutex->for_write()) { ... } }
    }

Taking either side wholesale would have reintroduced a bug: the upstream version
alone loses nested-fault safety; ours alone loses the scalability fix.

## Three build footguns the agent found (all real, all worth fixing)

1. **`image=open_zfs,...` shadows the ZFS module.** Passing `open_zfs` explicitly
   makes `resolve.require()` load it first; its `provides=['zfs']` registers it
   under the name `zfs`, so `modules/zfs/module.py` is never loaded and its
   `/usr/lib/fs/libsolaris.so` manifest line never reaches usr.manifest. With
   `fs=ramfs`, scripts/build uses usr.manifest AS the bootfs manifest, so
   libsolaris.so silently vanishes and the guest dies at "Failed to preload ZFS
   library." `image=zfs,zfs-tools,postgres18-musl` is correct.
   **This means PR #1494 may be treating a symptom** - it adds libsolaris.so to
   `bootfs_dep`, but the real bug here is caller-order module shadowing. #1494 does
   also fix a separate genuine `bootfs_dep` gap (fs=ramfs never gets `$(tools)`),
   so it is not wrong, just possibly aimed at the wrong one of two bugs. DO NOT
   close or amend #1494 until this is sorted out.
2. **The ZFS patch series can fail silently and ENTIRELY.** `patches/0031` has a
   malformed hunk header (`@@ -100,6 +100,14 @@` where the hunk has 5 context + 15
   new lines, so it should be `-100,5 +100,15`). `git apply` is atomic -> all 32
   patches fail -> and the Makefile hides it with
   `git apply ... 2>/dev/null && touch stamp`. ZFS then builds from pristine
   upstream with ZERO OSv platform patches and the guest dies at "trying to execute
   null pointer" in `taskqueue_thread_loop`. This is a live footgun for anyone
   building the branch and deserves its own fix (correct the hunk counts AND stop
   swallowing the error).
3. `patches/0032`'s second hunk is anchored at line 1 while the real code is at
   line 50 - needs GNU `patch --fuzz` or `--recount`.

## A separate crash worth its own report

After ~17 minutes of load: `page fault outside application, addr 0x2a2500000000`,
`RIP lockfree_mutex_lock+824`, `RDI 0x2a2500000000`, reached from `fflush+311`.
A `FILE` lock whose memory is not identity-heap-coherent across a forked child -
same family as the cross-AS coherence commits.

## Honesty note carried forward

The NOPM drop 288,460 -> 102,026 between the old and new base is NOT a measured
regression: the old figure came from a 60 GB pool that hit ENOSPC mid-sweep, the
new one used 300 GB, and the two may differ in whether the ZFS patch series applied
at all (see footgun 2). No controlled throughput A/B was run, so no throughput
claim is being made.

## UPDATE: the fault-side fix does NOT close the gate either (third cause exists)

Early signal from the re-test on wip/pg-v26-faultfix @ 73a332f26 (agent f18ef8dd):
probe at config A / VU32 recorded 11,690 ms and 10,989 ms samples mid-run. Gate
FAILS again, and the worst stall is currently WORSE than the ~7,800 ms measured
with only the virtio-blk fix.

Critically, the boring explanation is ruled out: the agent verified the fix is
really built and armed - `cow_peek_enabled` and `handle_cow_write_fault` present in
loader.elf, `OSV_MMU_COW_PEEK` defaults ON, and the resolved mmu.cc region reads as
intended. So the AS-wide-write-lock fix is active and there is a THIRD cause.

Two readings of "worse", to be distinguished in the final report:
(a) run-to-run variance - >=5s events are rare, so 2 samples is a tiny sample;
(b) real - removing the fault-path serialization let PG push harder into the actual
    bottleneck, lengthening the residual stall.
Discriminator: NOPM of this run vs the previous gate run's 102,026. NOPM up +
stall longer supports (b) and says the remaining cause is throughput-sensitive and
downstream of the fault path. NOPM flat with 1-2 samples means the delta is noise
and no regression should be claimed.

Third-cause hypothesis being tested: the earlier evidence (31 backends on
LWLock:WALWrite while IO:WalSync <= 2; sync=0.009s vs write=86-154s; disk starved;
guest CPU pegged) says the WAL *write submission* path is itself the serialized CPU
consumer - i.e. the ZFS write path under the WALWrite lock. Asked for a mid-stall
backtrace of a spinning vCPU (gdb on qemu, or host `perf record -p <qemu>`), which
would be decisive, and to check three specific CPU-bound-under-WALWrite suspects:
the ZIL commit path (zil_commit / lwb write), ARC eviction running hot while a
writer holds the lock, and the OSv page allocator / mempool refill.

Also asked to confirm on THIS build that ZFS patches 0031/0032 actually applied
(grep the built sources for `arc_reduce_target_size_shrink_sync`), because the
silent atomic patch-series failure documented above would leave ARC sizing
unpatched and is a plausible cause of exactly this signature.

Substrate deviation noted: the guest blocks forever on DHCP (no DHCP server on
br0), so this run boots with a static `--ip=eth0,192.168.100.2,255.255.255.0
--defaultgw=192.168.100.1`. Reasonable, but 10-11 s is suspiciously close to
DHCP/ARP retry windows, so the agent was asked to confirm the stalls do not
correlate with network retries - the earlier finding that an already-connected
persistent session also stalled argues against a network cause, but it needs one
line of confirmation on a static-IP boot.
