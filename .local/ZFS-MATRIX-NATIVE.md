# ZFS-MATRIX — NATIVE + ZFS cell (Part B)

Agent: osv-fc recon+de-risk. All on EC2 (AWS_PROFILE=fred, us-east-2).
Build: gh-fork wip/pg-tail-fix @ 79ed402f4 + 2 nitro cherry-picks (ena RSS 2161ebce, nvme MSI-X cap 690ec403).
App: gburd/osv-apps wip/postgres18-musl-demo @ c0d2bad (PG18.6-musl).

## INSTANCES (tagged osv-fc-*)
- i-07b4e60d4339cbac5  osv-fc-native-osv    m5d.2xlarge us-east-2b  (native OSv from AMI ami-0d98731cde1f60a82; local NVMe)
- i-063c642ee096088bb  osv-fc-native-linux  m5d.2xlarge us-east-2b  (native Linux, UBUNTU 24.04, ZFS 2.2.2, PG18.6 PGDG)
Native OSv AMI: ami-0d98731cde1f60a82 (fs=ramfs conf_fork=1 conf_zfs=openzfs +zfs-tools, PG18-musl baked).
Image vol vol-0837987811d77a4b5, snap snap-07c77ed3269e03a25.

## ============================================================================
## STEP B1 = PARTIAL. Native OSv boots + PG postmaster ready + fork wall CLOSED (ramfs),
## BUT two stacked blockers prevent a native ZFS serving number. (2026-08-18)
## ============================================================================

### What WORKS natively (m5d.2xlarge non-metal Nitro, real hardware, halt != VM-exit):
- fs=ramfs conf_fork=1 bare.raw AMI boots native: OSv v0.57.0-460, WAKE_PULL ON, eth0 up (ENA),
  1663ms. The native fork wall (fs=rofs demand-page-nested-in-fork crash) STAYS CLOSED via fs=ramfs
  (PG baked in loader, no demand-paging). Postmaster forks the startup process (pid 374, no crash),
  PG18.6 reaches "database system is ready to accept connections". So native boot + postmaster-fork
  both work -- consistent with NATIVE-TAIL's closed fork wall.

### BLOCKER 1 -- native ZFS pool cannot be created at runtime with an fs=ramfs image:
Boot cmdline `/zpool.so create ... pgdata /dev/vblk1` FAILED: console shows "/dev/zfs not found"
(twice). ROOT CAUSE: with fs=ramfs, OSv does NOT auto-run load_zfs_library_and_mount_zfs_root()
(loader.cc:499/574) which is what calls zfsdev::zfsdev_init() to create the /dev/zfs control device
+ init the OpenZFS kernel. fs=ramfs has no ZFS root to mount -> the ZFS kernel never initializes ->
/dev/zfs absent -> zpool/zfs commands cannot talk to the kernel -> pool create fails silently, PG
falls back to serving the baked ramfs /data (NOT ZFS).
  - `--preload-zfs-library` (loader.cc:611) only LOADS /usr/lib/fs/libsolaris.so into memory; it does
    NOT call zfsdev_init(), so /dev/zfs still absent. AND libsolaris.so is not even in the fs=ramfs
    manifest at /usr/lib/fs (it's baked into the loader only for fs=zfs).
  - The zfs-parity test harness (FINDINGS-osv-openzfs.md) used a dedicated /zfsinit.so that inits
    /dev/zfs + /etc/mnttab before zpool commands -- that helper is NOT in the app image.
  => THE EXACT GAP: native fs=ramfs (required to dodge the fork wall) lacks the ZFS-kernel-init path.
     FIX (code, not done): (a) add libsolaris.so to the image at /usr/lib/fs, (b) call zfsdev_init()
     at boot for fs=ramfs when a runtime pool is wanted (or ship a /zfsinit.so run before /zpool.so).
     This is a small, identified code/build change; out of recon scope.

### BLOCKER 2 -- native forked backends fail at RNG (independent of ZFS):
Even serving from the baked ramfs /data, every external connection FATALs:
  "FATAL: could not generate random cancel key"  (persistent, every forked backend)
The postmaster FORKS the backend fine (fork wall closed), but the child's pg_strong_random() for the
cancel key fails on this native Nitro box. This is OSv's native RNG path (RDRAND / drivers/random.cc)
failing WITHOUT a virtio-rng device -- the SAME class prior agents flagged. Under FIRECRACKER this did
NOT happen (FC/KVM env satisfied the RNG, backends served fine) -- it is specifically a native-EC2-Nitro
RNG gap. => even the fs=ramfs native RAMFS-data cell serves 0 client queries.

### BLOCKER 2 detail (confirmed persistent, NOT the seed race): retried external connects over 10min
uptime -- ALL still "could not generate random cancel key". So it is NOT the transient CSPRNG seed
race the code comment describes (drivers/random.cc:70-90) -- it is that processor::features().rdrand
returns FALSE on this native Nitro guest AND the software CSPRNG never crosses its reseed threshold
(no native entropy-harvesting source), so /dev/urandom blocks forever -> every backend FATALs.
CONTRAST: under FIRECRACKER the identical build served queries fine -- FC/KVM exposes a usable RNG to
the guest (RDRAND or fast seed), native OSv on this Nitro box does not. A precise, reproducible gap.
FIX (not done): make OSv's native RNG detect/use RDRAND on Nitro, or seed the CSPRNG from a boot
entropy source, or add a virtio-rng-equivalent -- small, identified, out of recon scope.

### VERDICT B1: native OSv boots + postmaster ready + fork wall closed, but NO native ZFS serving
number obtainable this run -- blocked by (1) no ZFS-kernel-init in the fs=ramfs image and (2) a
native RNG cancel-key failure in forked backends. Both are identified, both are small fixes, NEITHER
is the fork wall (which is closed). fork-on-zfs vs fork-on-ramfs could not be A/B'd because the ZFS
pool never came up natively. [B2 a2a not reachable this run -- gap banked]

### Native Linux-ZFS partner (ready, unused): i-063c642ee096088bb Ubuntu 24.04, ZFS 2.2.2, PG18.6
PGDG, local NVMe nvme1n1 279G -- staged for the a2a but OSv side has no serving number to compare.

## ============================================================================
## B SUMMARY: is native OSv-ZFS >=80% of native Linux-ZFS?  UNANSWERABLE this run (OSv served 0
## native queries). B2 a2a NOT reachable. The two native blockers (ZFS-kernel-init in fs=ramfs; RNG
## cancel-key on forked backends) are both identified + small + NOT the fork wall (which is closed).
## Cross-ref ZFS-MATRIX-FC.md: under FIRECRACKER the identical OSv build DID serve PG on ZFS 0-failed
## (A2 pass) -- so the native gaps are native-EC2-specific (no virtio-rng; fs=ramfs lacks zfsdev_init),
## NOT fundamental to OSv+PG+ZFS+fork. A next burner closes both small gaps then B2 is measurable.
## Recall NATIVE-TAIL: native FLATTENS the tail vs QEMU (c32 0.87x-of-peak vs 0.72x) -- so once the
## RNG+zfs-init gaps are fixed, native ZFS is plausibly OSv's best parity cell, but that is a
## PREDICTION, not a measured number this run.
## ============================================================================
