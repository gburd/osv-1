# ZFS-MATRIX — FIRECRACKER cell (Part A)

Agent: osv-fc recon+de-risk. All on EC2 (AWS_PROFILE=fred, us-east-2).
Build: gh-fork wip/pg-tail-fix @ 79ed402f4 (OSV_IDLE_SPIN on 2b8c02c9f fork-COW-nested-lockfree stack).
App: gburd/osv-apps wip/postgres18-musl-demo @ c0d2bad (PG18.6-musl, fs=zfs conf_zfs=openzfs image).

## INSTANCES (all tagged osv-fc-*)
- i-0b018b41ac38eda9b  osv-fc-host          m5d.metal   us-east-2b  (FC host + OSv image builder; /dev/kvm; 4x 838G NVMe)
- i-028d4333ae5cf31d8  osv-fc-native-osv    m5d.2xlarge us-east-2b  (Part B native OSv-ZFS; local NVMe nvme2n1 279G)
- i-063c642ee096088bb  osv-fc-native-linux  m5d.2xlarge us-east-2b  (Part B native Linux-ZFS; UBUNTU 24.04, ZFS 2.2.2, PG18.6 PGDG)

## FC ENVIRONMENT
Firecracker v1.7.0 (x86_64), AL2023 host, real /dev/kvm on m5d.metal.
OSv has FIRST-CLASS FC support: scripts/firecracker.py + the app's own fc-snap.py/fc-snapshot.sh
harness. Transport = virtio-mmio (--nopci), PVH/Linux-boot (loader-stripped.elf as kernel,
extract_linux_boot_params in arch/x64/vmlinux.cc), virtio-blk drives + virtio-net tap.

## ============================================================================
## STEP A1 = GO. OSv BOOTS UNDER FIRECRACKER WITH THE PG+ZFS STACK. (2026-08-18)
## ============================================================================
FC boot of loader-stripped.elf (kernel) + usr.raw (fs=zfs rootfs, virtio-blk) + fc_tap0 (virtio-net),
cmdline via boot_args, --nopci (forces virtio-mmio). Full console:

  OSv v0.57.0-458-g79ed402f         <- TARGET BUILD 79ed402f4
  WAKE_PULL off
  ZFS: OpenZFS 5000 initialized     <- OpenZFS kernel (libsolaris.so) linked + init under FC
  [ZFS] Pool 'osv' is up-to-date at version 5000   <- ZFS pool imported over virtio-mmio-blk
  ZFS: root mounted ok, z_root=34   <- OpenZFS root dataset mounted
  eth0: 192.168.100.2               <- virtio-net (virtio-mmio) UP
  Booted up in 138.05 ms
  PostgreSQL 18.6 ... listening on 0.0.0.0:5432   <- postmaster LISTENS under FC

VERDICT A1: OSv boots under Firecracker AT ALL with the PG+ZFS stack -- YES. virtio-mmio transport
(blk+net), OpenZFS init+import+mount, PVH direct-kernel boot all WORK under FC v1.7.0 on this build.
138ms cold boot. NO device/transport/boot-stage gap. The biggest unknown is CLOSED = GO.

## STEP A2 = PASS. PG SERVES FORKED BACKENDS ON ZFS UNDER FIRECRACKER. (2026-08-18)
The A1 image was conf_fork=0 (default) -> "fork() stubbed ... could not fork checkpointer: ENOSYS"
-> postmaster shut down. GOTCHA: the matrix needs FORKED backends -> rebuilt fs=zfs conf_zfs=openzfs
conf_fork=1 (CONF_fork=y verified; the fork-COW-nested-lockfree stack). Also had to force-regenerate
the stale .config (conf_fork=0 -> conf_fork=1 via `make -f conf/Makefile config conf_fork=1`; a stale
.config silently built conf_fork=0 -> fork.cc compile error thread::address_space missing).

With conf_fork=1 under FC:
  - OSv boots (146ms), OpenZFS root mounted, PG18.6 "ready to accept connections"
  - startup process FORKED OK (pid 338, no ENOSYS)
  - external psql over virtio-net: served-by 192.168.100.2, version PG18.6-musl
  - 4 CONCURRENT connections -> 4 DISTINCT forked backend pids (361/362/363/364) all served, 0 crash
VERDICT A2: PG serves forked backends under FC on OpenZFS -- YES, 0-crash.

NUANCE for A3 fairness: in this A2 boot the SERVING pgdata was a writable RAMFS /data (seed_copy from
/data-seed which lives on the zfs root) -- so active PG I/O hit ramfs, only the seed was on ZFS. A true
ZFS A3 benchmark needs PGDATA ITSELF on a ZFS pool. The app's fc-snapshot.sh do_boot does exactly this:
import a ZFS pool `pgdata` on a VIRTIO-BLK drive (/dev/vblk1) + `postgres -D /data`(=zfs mount). A3
uses that config so PG data is genuinely on OpenZFS-over-virtio-blk. [A3 to follow]

## STEP A3 - OSv-FC ZFS-on-virtio-blk serving CONFIRMED + numbers (2026-08-18)
Built image=postgres18-musl,zfs-tools fs=zfs conf_zfs=openzfs conf_fork=1 (added zfs-tools so
/zpool.so /zfs.so are on the image root). Boot cmdline creates the pool IN-GUEST on /dev/vblk1 (a
blank 8G raw file as a 2nd virtio-blk member) so pool version matches OSv's own OpenZFS (the skill's
dmu_objset_own gotcha avoided):
  /zpool.so create -f -o ashift=12 -O compression=off -O atime=off -O recordsize=8k -O logbias=latency
    -O primarycache=all -m /data pgdata /dev/vblk1 ; /zfs.so set sync=standard pgdata ;
    /usr/bin/seed_copy /data-seed /data ; /usr/bin/postgres -D /data
CONFIRMED: pool 'pgdata' imported (version 5000), PG ready, data_directory=/data(=ZFS), forked
backends serve, RW writes commit, 4 concurrent forked backends 0-crash. PGDATA genuinely on
OpenZFS-over-virtio-blk under FC.

### OSv-FC crash finding (real, load-dependent): under s50 + SUSTAINED RW + a large CHECKPOINT the
guest ABORTED with a page fault in a ZFS taskqueue thread:
  Aborted <- osv::handle_mmap_fault <- mmu::vm_fault <- page_fault <- ... <- taskqueue_thread_loop
This is the OpenZFS async-writeback (taskqueue) path hitting an mmap fault under checkpoint pressure.
At s10 the full RO+RW c1-c64 sweep is 0-failed + guest stays ALIVE (no crash) -- so the crash is
DATASET/CHECKPOINT-PRESSURE dependent (large s50 checkpoint), not a c-count wall. A genuine gap to
bank: OSv OpenZFS-over-virtio-blk under FC is not robust under heavy-checkpoint RW.

### OSv-FC sweep (s10 ZFS-on-virtio-blk, 8 vCPU, -S/TPC-B 15s x2 best, 0-failed gate, guest alive):
  conc   RO_OSv-FC   RW_OSv-FC
  c1     9391        1141
  c8     25325(peak) 2785(peak)
  c16    21658       2483
  c32    21529       2192
  c48    21911       2047
  c64    20741       1802
SHAPE: RO peaks c8 then flat ~21-22k plateau; RW peaks c8 then gently declines. 0-failed.
ABSOLUTE LEVEL: much lower than QEMU (RO c8 77k) / native (RO c8 49k) -- FC's minimal virtio-mmio
transport (no vhost offload, single-queue, InvalidDataLength descriptor warnings) is materially
slower than QEMU virtio-pci+vhost for this PG workload. This is expected FC-transport cost, not a
regression. [Linux-FC partner + ratio to follow]

## STEP A3 = COMPLETE. Apples-to-apples OSv-FC vs Linux-FC, both ZFS-on-virtio-blk under FC.
### Linux-FC leg BUILT (real, fair): extracted an uncompressed ELF vmlinux from Ubuntu 24.04's
6.17-aws bzImage (zstd payload at off 21196, 67MB ELF), built a 3G ext4 FC rootfs from the Ubuntu
userland + zfs.ko (v2.3.4) + PG18.6 PGDG, custom /fcinit.sh loads zfs, `zpool create` on /dev/vdb
(2nd virtio-blk), initdb, serves PG. GOTCHA: `zpool create` HANGS without udev -> fixed by starting
systemd-udevd + udevadm settle + a timeout guard before create. Linux boots under FC (ext4 root,
ZFS module loaded pool v5000), PG18.6 listens on 0.0.0.0:5432, data_directory on ZFS, shared_buffers
128MB (matched). So BOTH legs are genuinely under Firecracker with PGDATA on ZFS-over-virtio-blk.

### MATCHED CONFIG (both under FC v1.7.0, 8 vCPU, 4G mem, ZFS-on-virtio-blk pool -m /data|/pg,
### ashift=12 recordsize=8k compression=off atime=off sync=standard, PG18.6 shared_buffers=128MB
### max_connections=100 fsync=on io_method=sync, pgbench s10, -S/TPC-B 15s x2 best, 0-failed gate):
  conc   RO_OSv-FC   RO_Lin-FC   RO_ratio    RW_OSv-FC  RW_Lin-FC  RW_ratio
  c1     9391        9539        0.98x       1141       1128       1.01x   <- OSv PARITY c1 (RO+RW)
  c8     25325       48435       0.52x       2785       5103       0.55x
  c16    21658       72384       0.30x       2483       5877       0.42x
  c32    21529       88611       0.24x       2192       5964       0.37x
  c48    21911       87344       0.25x       2047       6112       0.33x
  c64    20741       85880       0.24x       1802       5539       0.33x

### A3 VERDICT: OSv PARITY at c1 (RO 0.98x, RW 1.01x), then falls to a ~0.24-0.25x RO plateau and
~0.33-0.37x RW plateau c16-c64. OSv is NOT >=80% of Linux under FC EXCEPT at c1. The shape is the
SAME process-per-connection tail seen in QEMU + native (OSv wins/ties c1, peaks c8, then a fixed
per-request decline while Linux climbs) -- so the tail is the fork model, not the FC transport. FC
ADDS a lower absolute ceiling on TOP (OSv-FC RO c8 25k vs QEMU 77k / native 49k = FC virtio-mmio is
~2-3x slower transport than QEMU vhost). Net: OSv-FC serves ZFS-on-virtio-blk correctly (RO+RW
0-failed at s10) but at ~0.24x RO / ~0.33x RW of Linux-FC at scale -- BELOW the 80% target.

### hp{on,off} NOTE: hugepages leg NOT run. FC v1.7.0 machine-config has no hugepage toggle in the
simple JSON path used here; OSv's own hugepage use is internal. The RO/RW plateau is dispatch/fork
bound (host idle at collapse in prior runs), so hugepages are not expected to move the >=80% verdict;
left as a labeled gap for the full-matrix burner.

### OSv-FC RW crash (banked above) recap: under s50 + sustained RW + a big checkpoint, OSv aborted in
a ZFS taskqueue mmap-fault. s10 sweep is 0-failed + guest alive. A real robustness gap under heavy
checkpoint on OpenZFS-over-virtio-blk under FC.
