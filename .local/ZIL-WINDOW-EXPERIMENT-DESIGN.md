# The decisive ZIL-window experiment: design (one variable = the commit-batch window)

## What the iowake run left ambiguous
The 448us OSv fdatasync was measured on `wip/pg-rx-directwake`, which has NEITHER the hires fix NOR the
HIRES_CV switch (verified: 0 hits for openzfs_cv_timedwait_hires). So it ran the OLD tick-truncating
cv_timedwait_hires. Under the old code, a sub-ms batch window truncates to 0 ticks and the waiter
returns immediately - so 448us was measured with the window effectively ALREADY SKIPPED. That refutes
my first hypothesis: the tax is NOT the honoured batch window, because the window was not honoured in
that run and it was still 448us.

## Corrected reading of the numbers
Old-code OSv (window skipped) fdatasync = 448us; Linux = 185us. So even with immediate lwb issue, OSv's
ZIL commit is 264us slower than Linux. The excess is in the LWB write + FLUSH + commit-waiter WAKEUP
machinery, NOT the batch-window wait. The zio_root(write child + flush child) both-complete requirement
plus the cv_broadcast round-trips is the remaining suspect.

## The experiment that actually isolates it (build ONE base, vary ONE thing at a time)
Base: cbbf74e7 (has the CORRECT hires fix) + the syncwrite isolate. Then instrument the ZIL commit to
report, per fdatasync, the time in each sub-phase:
  A. lwb write zio issue -> write_done       (should be ~6us, matches nofsync)
  B. flush zio issue -> flush_vdevs_done     (the device FLUSH; instance NVMe should be fast)
  C. flush_vdevs_done cv_broadcast -> waiter wakes and returns  (the WAKEUP hop)
  D. any batch-window wait (with correct hires: sleep = last_lwb_latency*10/100)
Sum should be ~442us; the dominant term names the fix. This needs a few gethrtime() probes in
zil.c/zil_lwb_* logged to a ring buffer the bench can read. That is a bench-only instrumentation patch,
not a product change.

## Candidate fixes, ranked, ALL generic (G2) - choose after the sub-phase measurement
1. If phase C (wakeup) dominates: the commit-waiter cv_broadcast -> waiter -> fdatasync-thread chain is
   too many hops. OSv scheduler wakeup latency across idle vCPUs (IPI) is the cost. Fix: wake the
   waiter directly / co-locate, or reduce the hop count in zil_lwb_flush_vdevs_done.
2. If phase B (flush) dominates: OSv's VIRTIO_BLK_T_FLUSH completion is slow, OR the flush is
   unnecessary on instance-store NVMe (no volatile cache). Fix: honour a "no volatile write cache" hint
   so ZFS skips the flush (upstream has vdev nowritecache handling - check if OSv advertises it).
3. If phase D (window) dominates on the CORRECT-hires base: the window should be 0 at low concurrency.

## Why this matters and stays honest
The iowake decomposition already delivered the big result: the tax is in fdatasync/ZIL commit, not
plain writes (nofsync identical to Linux). The sub-phase breakdown just picks which of B/C/D to fix.
Do NOT implement before that breakdown - I already wrote (and then had to retract) the "inline the
interrupt stage" idea and the "honoured window is the cost" idea; both were plausible and both wrong.
Measure the sub-phases first.

## Note on the flush hypothesis (cheap to check, could be the whole thing)
Instance-store NVMe has no volatile write cache to flush. If ZFS is issuing a real VIRTIO_BLK_T_FLUSH
per commit and the guest/host honours it as a full barrier, that is pure overhead on this hardware.
Linux ZFS may be detecting nowritecache and skipping it. CHECK: does OSv's vdev_disk advertise
nowritecache, and does the host qemu/virtio-blk expose a volatile cache? If OSv flushes and Linux does
not, that ALONE could be the 264us - and the fix (advertise nowritecache / honour it) is generic.
