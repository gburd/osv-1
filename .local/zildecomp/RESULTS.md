# ZIL-commit sub-phase decomposition -- RESULTS (in progress)

Box: i-059a8c1347bd1c46e  m5d.metal  us-east-2  Owner=agent-zildecomp
NVMe both arms: /dev/nvme1n1 (838G instance-store)
OSv: v0.57.0-460-gf45dac0d, OpenZFS 2.4.x (userland reports zfs-2.4.1-osv)
Guest: 8 vCPU / 8 GiB, KVM, -M pc, qemu 8.1.3 (fedora:39 container), NVMe as
       virtio-blk (vblk1). Pool: ashift=12 recsize=8k comp=off atime=off.
Bench: single thread, 8k pwrite [+ fdatasync], secs=20 reps=3. medians of 3.

## OSv sync-mode sweep (experiment 1) -- p50/p99 us

| config                         | p50 us | p99 us | op/s   |
|--------------------------------|-------:|-------:|-------:|
| syncwrite sync=standard        | 363.0  | 701.7  | 2695   |
| syncwrite sync=disabled        | 297.9  | 621.7  | 3331   |
| syncwrite sync=always          | 363.3  | 720.0  | 2706   |
| syncwrite nofsync (no fdatasync)|   6.2  |  46.8  | 97296  |
| syncwrite nofsync sync=disabled |   5.7  |  58.5  | 97445  |

## THE SURPRISE (refutes the B-flush / C-wakeup / D-window framing as posed)

sync=disabled makes fdatasync a SEMANTIC NO-OP: no ZIL log block (LWB), no
device FLUSH -- the whole ZIL commit path is bypassed. Yet p50 only drops from
363.0 to 297.9 us. It does NOT drop to the ~6 us that "no fdatasync at all"
(nofsync) gives.

Decomposition of the 363 us OSv fdatasync p50:
  - plain 8k write completion (nofsync):                  ~6 us
  - fdatasync CALL overhead that survives sync=disabled: ~292 us  <-- dominant
  - the actual ZIL log-write + device FLUSH (std - disabled): ~65 us

So the dominant term (~292 of ~357 us above the plain write) is NOT the flush
(B) and NOT the ZIL commit-waiter wakeup for a real LWB (C) and NOT the batch
window (D). It is the cost of the fdatasync() syscall PATH ITSELF on OSv ZFS,
incurred even when sync=disabled turns the ZIL commit into a no-op.

The ZIL-log-write + flush round-trip (B) is only ~65 us of the tax. That is the
ONLY part experiment 2 (flush mode) can move. Even eliminating the flush
entirely cannot remove the ~292 us fdatasync-path cost.

## Controls that make this airtight
- nofsync (fdatasync never called): 6.2 us -> confirms plain write path is cheap
  on OSv, matches prior isolate.
- nofsync sync=disabled: 5.7 us -> sync mode alone changes nothing without a
  fdatasync call; the cost is specifically in EXECUTING fdatasync.

## ROOT CAUSE (traced + CONFIRMED by file-size scaling)

OSv `fdatasync` -> `fsync` -> `sys_fsync` (fs/vfs/vfs_syscalls.cc:380) calls
`pagecache::writeback_inode(dev, ino, 0, st_size)` on the WHOLE FILE before
`VOP_FSYNC`. `writeback_inode` (core/pagecache.cc:1025) scans `0..st_size` in
4096-byte steps TWICE (phase 1 promote-dirty, phase 2 collect), each step a
`find_in_cache()` hash lookup under the global `write_lock`. That is an
O(filesize) scan on EVERY fsync. For a `write()`-based writer (PostgreSQL, and
this bench's pwrite) the write_cache (MAP_SHARED mmap pages only; insert() is
reached solely from the mmap fault path, never pwrite) is EMPTY for the inode,
so the scan finds nothing and flushes nothing -- pure waste -- yet still runs
full length.

Arithmetic: 1 GiB / 4096 = 262,144 pages x2 phases ~= 524k hash lookups/fsync
~= the ~292 us fdatasync-entry tax. Explains checkpoint-slows-with-DB-size.

## DECISIVE TEST: fdatasync p50 scales LINEARLY with file size (sync=disabled)

sync=disabled => ZIL commit fully bypassed (no LWB, no device FLUSH). Any
remaining latency-vs-size slope is PURELY the writeback_inode scan.

| file cap (MiB) | fdatasync p50 us (sync=disabled) |
|---------------:|---------------------------------:|
|   8            |  11.3   |
|  64            |  73.7   |
| 256            | 283.3   |
| 512 (secs=45)  | 489.9   |

8->64->256 is dead linear at ~1.1 us/MiB (~4.5 ns per page x2). At 512 MiB the
fdatasync p50 is 489.9 us -- with the ZIL commit DISABLED -- already exceeding
the prior run's 448.7 us "full ZIL+flush" figure. Caps >=1024 plateau only
because a 45 s run cannot grow the file past ~512 MiB at ~22 MB/s before the
offset wraps; the scanned size, not the cap, sets the cost. LINEAR-IN-FILESIZE
CONFIRMED.

## VERDICT (names the phase and refutes the B/C/D framing as posed)

The dominant OSv per-fdatasync tax is NONE of B (flush), C (ZIL commit-waiter
wakeup), or D (batch window). It is a VFS-layer defect ABOVE the ZIL:
`sys_fsync`'s unconditional whole-file `writeback_inode` scan, which is
O(filesize) per fsync and finds zero dirty pages for a pwrite/write() workload.
  - plain 8k write (nofsync):                    ~6 us
  - writeback_inode whole-file scan (dominant):  ~290 us at ~256 MiB file,
                                                 scales linearly with file size
  - ZIL log-write + device FLUSH (std - disabled): ~65 us   <- the ONLY part
                                                 experiment 2 can move

Fix target: make `writeback_inode` not scan clean ranges -- skip the scan when
the inode has no cached dirty write-pages (track a per-inode dirty count, or
keep a per-inode interval set of dirty offsets), or short-circuit when the
global write_cache is empty. Generic OSv win for every fsync-heavy workload
(PostgreSQL checkpoints, any write()+fsync durable path).

## PROOF the scan finds NOTHING (writeback_inode page counters, pwrite workload)

Instrumented writeback_inode (bench-only counters, core/pagecache.cc) and had
the bench print them. pwrite workload, sync=disabled:

| capmb | fsync calls | pages_scanned | pages_flushed | avg pages/call  | p50 us |
|------:|------------:|--------------:|--------------:|----------------:|-------:|
|  64   |  186,322    | 2,985,582,592 |      0        |  16,024 (62MiB) |  78.4  |
| 256   |   63,314    | 3,075,571,712 |      0        | 48,577 (190MiB) | 302.0  |

pages_flushed = 0 in EVERY run. The scan touches billions of page slots and
flushes exactly zero -- write_cache holds only MAP_SHARED mmap pages and this
workload never mmaps. avg-pages-scanned/call tracks file size; p50 tracks
avg-pages-scanned. Empty-but-O(filesize): confirmed empirically, not by trace.

## EXPERIMENT 2: host flush mode (isolates phase B), small file capmb=8 (scan~11us)

sync=standard, capmb=8 so the writeback scan is a fixed ~11 us and the ZIL
commit + device FLUSH dominate the remainder. One variable = qemu host cache
mode on the NVMe drive (whether the guest FLUSH reaches a device barrier).

| host cache mode    | flush behaviour        | aio     | p50 us |
|--------------------|------------------------|---------|-------:|
| cache=writethrough | FLUSH honored (barrier)| threads | 125.8  |
| cache=unsafe       | FLUSH dropped by host  | threads |  93.3  |
| cache=none         | FLUSH honored (direct) | native  | 114.9  |

Clean A/B (both aio=threads): writethrough 125.8 vs unsafe 93.3 =>
**device FLUSH round-trip (phase B) = ~32 us.** Even phase B is minor;
corroborates the sync-sweep's ~65 us for the whole ZIL-log-write + flush.

## FULL DECOMPOSITION of the OSv per-fdatasync latency (single thread, QD1)

  plain 8k write (no fsync):                 ~6 us
  fixed fdatasync/VFS/ZIL-entry overhead:   ~50 us   (at small file)
  device FLUSH round-trip (phase B):        ~32 us
  writeback_inode whole-file scan:          ~11 us @ 8 MiB file
                                            ~290 us @ 256 MiB file
                                            LINEAR in file size, flushes 0

The scan is the ONLY term that grows without bound; at any realistic file size
(a Postgres data file, a >100 MiB table) it dwarfs everything else. Fix target.
Flush (B) ~32 us and ZIL wakeup (C) are real but small and fixed.

## NEXT
- Linux arm (reboot 6.1 + OpenZFS 2.2.7) matched comparison.
