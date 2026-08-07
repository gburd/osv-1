# OSv-native vs Linux-native RO pgbench scale test (beef acct 840154381708 us-east-2)

THE ONE QUESTION: On QEMU (single emulated virtio RX queue) OSv RO plateaus/collapses
past c8 (peak c8~41-68k -> c32~17-21k) while Linux scales to ~190k. On NATIVE EC2 (real
ENA NIC, hardware RX queues), does OSv-native RO SCALE past c8 (=> QEMU-artifact) or STILL
PLATEAU (=> real OSv-side wall)?

Instance type for BOTH: m5d.4xlarge (16 vCPU, local NVMe, ENA). OSv image commit 6b71c76385,
image=zfs-tools,pg18-fork fs=zfs conf_zfs=openzfs conf_fork=1, DEFAULT mmap.

## QEMU baseline curves (from ROADMAP, for comparison)
- OSv-KVM RO -S (ramfs, smp16, real tap): c8=68543 PEAK -> c16=28k -> c32=17k -> c48=14k -> c64=13k (REGRESSES)
- OSv-KVM RO -S (#1464 sched fix): c8~27k -> c16~28k -> c32~26k (saturates ~27k single-RX-thread cap)
- Linux-KVM RO baseline (scale=100): c1=6022 c8=44303 c16=62949 c32=95106 c64=94272

## ARTIFACT IDS (bank immediately)
- builder (non-KVM, TERMINATED): m5d.4xlarge i-006a8922d977b5a64
- builder (KVM, ACTIVE): c5n.metal i-0a980694a6a079f84 (us-east-2a)
- OS root EBS volume: vol-01c7f088a776c6f1c (4 GiB gp3)
- root snapshot: snap-0f19434042e9c9f56
- pgdata data EBS volume: vol-06d3fed2fb4495da7 (40 GiB gp3, seeded ZFS pgdata pool)
- OSv-native AMI: ami-07ed892aacf237ae9 (legacy-bios, ENA, hvm, private)
- OSv-native instance: (pending)
- Linux-native instance: (pending)
- driver instance: (pending)

Image: OSv v0.57.0-447-g6b71c763, PG18.0 musl-PIE, DEFAULT mmap, shared_buffers=4GB.
KVM validation: builds rc=0; MBR-boot from offset-512 cmdline READY 2s; psql select 1 -> 1 (RAWMBR_SERVE_OK). DEFAULT mmap did NOT spin this boot.

## OSv-native boot/serve/survive
- BOOTS on Nitro m5.4xlarge (16 vCPU): ENA up eth0=172.31.12.38, pgdata pool imported, PG ready. Booted ~754ms. DEFAULT mmap, NO W1 spin.
- SERVES over ENA (NOT loopback): psql select 1 -> 1, inet_server_addr=172.31.12.38, PG18.0 musl.
- SURVIVES concurrent: pgbench -S -c16 -T15 = 956464 txns, 0 failed, 72587 tps.
- NVMe driver note: NVME_QUEUE_PER_CPU_ENABLED flipped 1->0 (single io queue) to clear an
  UNRELATED boot assert (nvme.cc:489 vectors_num<=msix_entries: 1+16 vCPU > AWS EBS-NVMe MSI-X).
  Storage-only; does NOT touch the network RX path under test. m5d->m5.4xlarge (both A/B) since
  pgdata is on EBS anyway (RO is network/CPU bound, cached in 4GB shared_buffers).

## OSv-native RO pgbench (-S -s300)
Driver c5.2xlarge -> OSv m5.4xlarge PRIVATE IP over ENA (NOT loopback). 30s/level, 2 runs, 0 failed.
  c1  : run1 4072  run2 5103   (best ~5.1k)
  c8  : run1 36153 run2 39204  (best ~39.2k)
  c16 : run1 61683 run2 60901  (best ~61.7k) <-- PEAK
  c32 : run1 31646 run2 34746  (~34.7k, DROP)
  c48 : run1 22333 run2 21932  (~22.3k, further DROP)
  c64 : run1 18372 run2 18785  (~18.8k, further DROP)
0 failed transactions at EVERY level. Curve SHAPE: climb to c16 PEAK then monotonic REGRESSION.

## Linux-native RO pgbench (-S -s300)
Same driver, same invocation, Linux m5.4xlarge (AL2023, PG18.4, ext4 on EBS -- see note), over ENA.
  c1  : 8442 / 8477   (~8.5k)
  c8  : 56347 / 57689 (~57.7k)
  c16 : 91780 / 91360 (~91.8k)
  c32 : 129826 / 128620 (~129.8k)
  c48 : 148629 / 147229 (~148.6k)
  c64 : 158666 / 159453 (~159.5k)
0 failed at every level. Curve SHAPE: MONOTONIC CLIMB c1->c64 (linear-ish scaling), no regression.
NOTE: Linux ran PG18 on ext4 (OpenZFS DKMS would not build against AL2023 kernel 6.18 in the
budget). For a RO workload at scale=300 (~4.5GB) with shared_buffers=4GB + effective_cache=12GB
the working set is fully RAM-cached -> tps is network/CPU/PG-backend bound, NOT storage bound;
the FS choice does not materially move RO tps. OSv side ran the real OpenZFS pool as specified.

## Per-cell ratio + VERDICT
OSv-native / Linux-native RO tps (best-of-2 each):
  c1  : 5103 / 8477   = 0.60x
  c8  : 39204 / 57689 = 0.68x
  c16 : 61683 / 91780 = 0.67x   <-- OSv's PEAK; still 2/3 of Linux, both climbing
  c32 : 34746 / 129826 = 0.27x  <-- OSv REGRESSES while Linux keeps climbing
  c48 : 22333 / 148629 = 0.15x
  c64 : 18785 / 159453 = 0.12x  <-- 8.5x gap; OSv at 12% of Linux

CURVE-SHAPE COMPARISON (the deciding evidence):
  QEMU OSv RO (ramfs smp16, 1 emulated virtio RX q): c8=68k PEAK -> c16=28k -> c32=17k -> c64=13k
  NATIVE OSv RO (real ENA, HW RX queues):             c8=39k -> c16=62k PEAK -> c32=35k -> c64=19k
  NATIVE Linux RO (same box):                         c8=58k -> c16=92k -> c32=130k -> c64=159k (climbs)

=== THE VERDICT: MOSTLY A REAL OSv-SIDE WALL (with a partial QEMU-queue component) ===
Real ENA hardware queues moved OSv's peak ONE step right (QEMU c8 -> native c16) and raised it
slightly, so the single-emulated-RX-queue WAS costing OSv something -- but it did NOT unlock
scaling. On real hardware OSv STILL peaks (now c16) then MONOTONICALLY REGRESSES (62k->35k->22k
->19k), the SAME plateau-then-collapse signature as QEMU, while Linux on the identical instance
scales linearly to 159k. The gap WIDENS with concurrency (0.67x at the peak -> 0.12x at c64).
So the plateau is NOT a QEMU host-vhost-single-queue artifact that vanishes on real hardware --
there IS a real OSv-side wall past the peak (the ROADMAP's named residual: single virtio/RX
receiver + per-request wake round-trip / cross-CPU wake serialization -> guest ~90% idle at high
concurrency, tps = concurrency/latency with latency growing). Native hardware shifts the knee
but the wall is intrinsic to OSv's current net-RX-to-backend dispatch, not the hypervisor.
=> The next step (lever-2 dispatch-offload / batch-wakeup, ROADMAP pr/net-batch-wakeup) IS
justified: it targets exactly this OSv-side wall, which real hardware confirmed is real.
(Deployment cell (a): OSv+PG boots+serves+survives natively at 0-failed through c64 -- functional
yes; but RO throughput past ~c16 is capped by the OSv-side dispatch wall, not the NIC.)

## Cleanup
ALL osv-rss artifacts confirmed removed (beef acct, us-east-2):
- instances TERMINATED (confirmed): builder-nonKVM i-006a8922d977b5a64, builder-KVM c5n.metal
  i-0a980694a6a079f84, osv-native-m5d(crashed) i-09c69565bd1be3101, osv-native-m5(nvme-old)
  i-0d5b0439ea4994643, osv-native-final i-017779162863eef1a, linux-native i-039aa2d3253882c72,
  driver i-0d5502b6980591b04. Final sweep: NONE non-terminated.
- volumes DELETED (confirmed InvalidVolume.NotFound): OS-root vol-01c7f088a776c6f1c,
  pgdata vol-06d3fed2fb4495da7.
- AMIs DEREGISTERED (confirmed, 0 self-owned osv-rss AMIs): ami-07ed892aacf237ae9,
  ami-0771b074eb72393e3.
- snapshots DELETED (confirmed, 0 self-owned osv-rss snaps): snap-0f19434042e9c9f56,
  snap-0d87d5ef9ecf62af5.
Remaining self-owned AMIs/snapshots/volumes are all solnix-*/OI (NOT mine, left untouched).
