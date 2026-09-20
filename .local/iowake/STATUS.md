# iowake latency-decomposition run status

Box: i-00f11bfe4f947797d  m5d.metal  us-east-2  Owner=agent-iowake
IP: 18.191.174.165
NVMe for both arms: /dev/nvme1n1 (838G instance-store)

## Setup state
- /dev/kvm present, 4 instance-store NVMe (nvme0-3n1, 838G each)
- Host ZFS: OpenZFS 2.3.4 built against running 6.12.103 kernel, module loaded. zpool @ /usr/local/sbin/zpool
- OSv arm: osv-1 clone at f45dac0db (wip/pg-rx-directwake, pushed to gburd/osv-1), syncwrite present
  - openzfs submodule 6330a45b (zfs-2.4.2)
  - building zfs_builder.elf + zfs-bench.so in fedora:39 container 'bld'

## Version note (confound to report)
OSv arm uses OpenZFS 2.4.2; Linux arm uses OpenZFS 2.3.4. Completion path
(zio_interrupt -> INTERRUPT taskq -> zio_done cv_signal) is identical across
2.3/2.4, so acceptable for the completion-path decomposition. Noted.

## Pool geometry (both arms, matched)
ashift=12 recordsize=8k compression=off atime=off sync=standard logbias=latency primarycache=all
(sync/logbias/primarycache are ZFS defaults; harness sets ashift/comp/atime/recsize explicitly)

## Workloads
syncwrite bs=8192 secs=30 reps=3          -> total per-durable-write p50/p99
syncwrite bs=8192 secs=30 reps=3 nofsync=1 -> write-completion only p50/p99

## FINAL (2026-09-12)
Both arms measured. See RESULTS.md.
Instance i-00f11bfe4f947797d TERMINATED. Root vol-0b0155cab7234c28f deleted.
Orphan check: 0 tagged instances, 0 of my volumes. (One 20GiB available volume
predates the run by a day, untagged, not mine.)

VERDICT: The OSv per-durable-write tax lives in the ZIL/flush commit-completion
path, NOT the general write-completion (zio interrupt-taskq) hop. nofsync p50
matches Linux (6.1 vs 6.5 us); the full fsync path shows +263.5 us OSv excess.
Fix target = the ZIL commit-completion wakeup (zio_done cv_signal), not inlining
the generic interrupt stage.
