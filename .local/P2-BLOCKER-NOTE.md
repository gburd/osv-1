## P2 TASK-2 BLOCKER (2026-09-05): possible THIRD aarch64 bug - seed_copy hangs reading /data-seed

WORKING on the 32-vCPU/48GB aarch64 guest (both P2 fixes in):
- boots ~250-300ms, 32 CPUs, net up (ping 0.039ms)
- OpenZFS 5000 init; pool pgdata CREATED + IMPORTED on the 60G virtio-blk
  (59.5G, ONLINE, mounted /data)
- ZFS WRITES WORK (51.6M of seed data landed)
- postgres --version -> PostgreSQL 18.6; seed_copy with no args exits cleanly

BLOCKER: any seed_copy that READS /data-seed hangs forever. The agent's own
evidence narrows it well:
- hangs to ZFS /data AND to RAMFS /data (ZFS entirely uninvolved)
- hangs on a SINGLE file (PG_VERSION), so NOT the 1292-file walk or tree size
- hangs at the old known-good -smp 4 -m 3G ramfs config, so it PREDATES and is
  independent of the map + GIC fixes
- control: a nonexistent source path fails fast and correctly
=> the problem is READING a bootfs/ramfs-resident file on aarch64, not the
destination filesystem.

AGENT HYPOTHESIS (/data-seed belongs on ROFS; ramfs breaks it) is LIKELY WRONG.
I verified the x86_64 48GB/32vCPU runs used fs=ramfs with the SAME /data-seed and
seed_copy, and they worked every time (fs=ramfs
image=open_zfs,zfs,zfs-tools,postgres18-musl; boot --preload-zfs-library
--rootfs=ramfs). The single-file hang also rules out tree size.

STEERED away from a wasted fs=rofs rebuild toward a bounded (30-45 min) root
cause:
1. confirm --preload-zfs-library is on the cmdline (its absence has caused
   confusing wedges before)
2. gdb the wedged thread and all threads: blocked in read/uio, a page fault, a
   mutex/condvar wait, or spinning?
3. discriminators: does a trivial small bootfs file read hang too, and does it
   hang at -smp 1 (isolates the read path from GIC/IPI/timer-park)
4. try the same image on x86_64: if x86 does not hang, it is cleanly
   aarch64-specific and upstreamable like the other two
Fall back to fs=rofs ONLY to unblock TASK 3, reporting the ramfs hang as an open
bug with whatever evidence exists.
