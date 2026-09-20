# ZFS-MATRIX-QEMU — the first ZFS-vs-ZFS parity matrix cell (PG/OSv vs PG/Linux, hugepages{on,off})

Agent: osv-zfsq-mtx. AWS_PROFILE=fred (acct 443433794128) us-east-2.
Instance: **i-073904e1def952353** (m5d.metal, us-east-2b, 96 vCPU real KVM, 4x838G local NVMe).
Substrate per .agent/skills/osv-fair-benchmark (STRICT): BOTH guests on ONE m5d.metal host,
identical qemu 9.1.3 (fedora:41 qemu-runner container, --network host --device /dev/kvm --privileged),
smp16, N=16 (mq) vhost tap on br0, driven over the tap IP (192.168.100.2 OSv / 192.168.100.3 Linux,
NOT loopback), ZFS pool on LOCAL NVMe raw files (nvme3=osv nvme4=linux, NO EBS in data path).
Driver = pgbench 18.6 in an ubuntu:24.04 container on the host network (over the tap, not loopback).

- OSv build: gh-fork **wip/pg-tail-fix @ 79ed402f4** (MQ+PULL+parked-timer+fork-COW-nested-lockfree
  +idle-spin), **conf_fork=1 fs=zfs conf_zfs=openzfs** image=open_zfs,zfs,zfs-tools,postgres18-musl.
  Boot banner: `OSv v0.57.0-458-g79ed402f`, `WAKE_PULL ON`, `ZFS: OpenZFS 5000 initialized`.
  postgres18-musl app @ apps c0d2bad, PG **18.6** (musl, x86_64-pc-linux-musl).
  Pool `pgdata` created **IN-GUEST** on vblk1 with OSv's own OpenZFS (no host-bake -> no
  dmu_objset_own ENXIO). ZFS root pool `osv` = usr.img (fs=zfs, zfs_builder-populated).
- Linux: Ubuntu 24.04 guest, OpenZFS **2.2.2** (zfsutils-linux in-repo), PG **18.6** (PGDG),
  pool `pgdata` on vdc, initdb --locale=C --encoding=SQL_ASCII.

============================================================================
## CONFIG-MATCH PROOF (the apples-to-apples evidence, per the fairness rule)
============================================================================

### ZFS — matched OpenZFS-vs-OpenZFS (NOT ext4)
Both pools, IDENTICAL property set, all SOURCE=local:

OSv `pgdata` (`/zpool.so get ashift` + `/zfs.so get`, from the OSv guest serial):
```
NAME    PROPERTY      VALUE       SOURCE
pgdata  ashift        12          local
pgdata  recordsize    8K          local
pgdata  compression   off         local
pgdata  atime         off         local
pgdata  sync          standard    local
pgdata  logbias       latency     local
pgdata  primarycache  all         local
```
Linux `pgdata` (`zpool get ashift` + `zfs get`, from the Ubuntu guest) — BYTE-IDENTICAL:
```
NAME    PROPERTY      VALUE       SOURCE
pgdata  ashift        12          local
pgdata  recordsize    8K          local
pgdata  compression   off         local
pgdata  atime         off         local
pgdata  sync          standard    local
pgdata  logbias       latency     local
pgdata  primarycache  all         local
```
=> Storage matched OpenZFS(OSv-in-kernel)-vs-OpenZFS(2.2.2). No ZFS-vs-ext4 conflation.

### PostgreSQL — SHOW-verified matched (both PG18.6)
| setting             | OSv        | Linux      |
|---------------------|------------|------------|
| server_version      | 18.6       | 18.6       |
| shared_buffers      | 16384(128MB)| 16384(128MB)|
| max_connections     | 100        | 100        |
| fsync               | on         | on         |
| synchronous_commit  | on         | on         |
| io_method           | sync       | sync       |
| huge_pages          | set per-cell via `-c huge_pages=on|off` (see sub-cells) |

huge_pages controlled PER SUB-CELL:
- hpOFF: both PG `huge_pages=off`, qemu no `-mem-path` (4K pages).
- hpON:  both PG `huge_pages=on`, qemu `-mem-path /dev/hugepages -mem-prealloc` (guest RAM on host 2MB pages).

============================================================================
## STATUS
============================================================================
- [x] instance launched + tooling (docker, qemu 9.1.3 container, nbd)
- [x] OSv fs=zfs conf_zfs=openzfs image built (usr.img zfs_builder-populated 60M)
- [x] Linux Ubuntu 24.04 + OpenZFS 2.2.2 + PG18.6 guest up
- [x] both ZFS pools created + config-match proven (above)
- [x] both PG18.6 up, SHOW-matched, reachable over tap, seeded pgbench -i -s50
- [x] OSv-hpOFF sweep (below)
- [x] OSv-hpON, Linux-hpOFF, Linux-hpON — RO+RW c1..c64 3-round median (below)
- [x] ratios + verdict (below)
- [x] cleaned up + terminated (see CLEANUP)

### NOTE: OSv RW c64 fd-accumulation wedge (measured)
Over a long single-instance sweep (~48 pgbench invocations), OSv PG exhausts its global fd
table under RW load and wedges with `pipe() failed: EMFILE` (postmaster forks 1 OS process +
pipes per backend; rapid c64 RW connect/disconnect accumulates fds faster than they are reaped).
The guest stays UP; only PG wedges. A FRESH OSv boot does RW c64 cleanly (6171 tps 0-failed).
=> RW c64 reported from a dedicated fresh short run; the accumulation wedge is a real OSv-on-ZFS
   ceiling at sustained high-concurrency RW, footnoted, not a benchmark failure.

============================================================================
## RAW SWEEP DATA
============================================================================
### OSv-hpOFF (fs=zfs, PG huge_pages=off, qemu 4K pages, smp16, N=16 vhost, 3-round median, 0-failed)
RO: c1 6953 (0.144ms) | c8 24627 (0.325) | c16 24675 (0.648) | c32 22536 (1.420) | c48 22066 (2.175) | c64 21238 (3.013)
RW: c1 1050 (0.952ms) | c8 3836 (2.085) | c16 4253 (3.762) | c32 4654 (6.876) | c48 4730 (10.148) | c64 6171* (*fresh-boot, sweep-accumulated wedge)
(RO peaks ~c8-16 25k then gentle decline; RW climbs to c48; 0-failed all cells.)

### OSv-hpON (fs=zfs, PG huge_pages=on, qemu -mem-path /dev/hugepages -mem-prealloc = guest RAM on host 2MB pages, smp16, N=16 vhost, 3-round median, 0-failed)
HugePages consumed: 16384 (32G) of 20480 reserved; PG SHOW huge_pages=on.
RO: c1 6100 (0.164ms) | c8 18682 (0.428) | c16 18363 (0.871) | c32 17027 (1.879) | c48 16232 (2.957) | c64 15404 (4.155)
RW: c1 1013 (0.987ms) | c8 3603 (2.221) | c16 4076 (3.925) | c32 4480 (7.142) | c48 4600 (10.435) | c64 6160* (*fresh-boot)
=> HUGEPAGES HURT OSv RO markedly (c8 18682 vs hpOFF 24627 = -24%; c64 15404 vs 21238 = -27%);
   RW essentially unchanged (within noise). See verdict.

### Linux-hpOFF (OpenZFS 2.2.2, PG huge_pages=off, qemu 4K pages, smp16, N=16 vhost, 3-round median, 0-failed)
RO: c1 7996 (0.125ms) | c8 73323 (0.109) | c16 134496 (0.119) | c32 141512 (0.226) | c48 138887 (0.346) | c64 137277 (0.466)
RW: c1 1028 (0.973ms) | c8 6513 (1.228) | c16 9341 (1.713) | c32 11586 (2.762) | c48 12970 (3.701) | c64 13390 (4.780)
(Linux climbs RO to c16-32 141k then holds; RW climbs monotonically to c64; 0-failed all cells.)

### Linux-hpON (OpenZFS 2.2.2, PG huge_pages=on, guest vm.nr_hugepages=256 + qemu -mem-path -mem-prealloc, smp16, N=16 vhost, 3-round median, 0-failed)
RO: c1 7566 (0.132ms) | c8 72368 (0.111) | c16 133371 (0.120) | c32 144094 (0.222) | c48 139510 (0.344) | c64 138704 (0.461)
RW: c1 1177 (0.850ms) | c8 7264 (1.101) | c16 9663 (1.656) | c32 13041 (2.454) | c48 14419 (3.329) | c64 14862 (4.306)
=> hugepages NEUTRAL for Linux RO (c32 144094 vs hpOFF 141512, within noise); small RW LIFT
   (c32 13041 vs 11586 +13%; c64 14862 vs 13390 +11%).

============================================================================
## THE 4-SUB-CELL MATRIX + OSv/Linux RATIOS
============================================================================

### READ-ONLY (pgbench -S), tps, 3-round median, 0-failed
| c  | OSv-hpOFF | OSv-hpON | Lin-hpOFF | Lin-hpON | ratio hpOFF | ratio hpON |
|----|-----------|----------|-----------|----------|-------------|------------|
| 1  | 6953      | 6100     | 7996      | 7566     | 0.87        | 0.81       |
| 8  | 24627     | 18682    | 73323     | 72368    | 0.34        | 0.26       |
| 16 | 24675     | 18363    | 134496    | 133371   | 0.18        | 0.14       |
| 32 | 22536     | 17027    | 141512    | 144094   | 0.16        | 0.12       |
| 48 | 22066     | 16232    | 138887    | 139510   | 0.16        | 0.12       |
| 64 | 21238     | 15404    | 137277    | 138704   | 0.15        | 0.11       |

### READ-WRITE (pgbench TPC-B), tps, 3-round median, 0-failed (*OSv c64 = fresh-boot, sweep-wedge)
| c  | OSv-hpOFF | OSv-hpON | Lin-hpOFF | Lin-hpON | ratio hpOFF | ratio hpON |
|----|-----------|----------|-----------|----------|-------------|------------|
| 1  | 1050      | 1013     | 1028      | 1177     | 1.02        | 0.86       |
| 8  | 3836      | 3603     | 6513      | 7264     | 0.59        | 0.50       |
| 16 | 4253      | 4076     | 9341      | 9663     | 0.46        | 0.42       |
| 32 | 4654      | 4480     | 11586     | 13041    | 0.40        | 0.34       |
| 48 | 4730      | 4600     | 12970     | 14419    | 0.36        | 0.32       |
| 64 | 6171*     | 6160*    | 13390     | 14862    | 0.46*       | 0.41*      |

============================================================================
## THE ANSWER
============================================================================

### Is OSv >= 80% of Linux, and where does it fall below?
NO — OSv is >=80% of Linux ONLY at c1 (RO 0.87 hpOFF / 0.81 hpON; RW 1.02 hpOFF, 0.86 hpON).
It falls below 80% the moment concurrency rises above 1:
- RO: the 80% line is crossed between c1 and c8. At c8 OSv is already 0.34x (hpOFF) / 0.26x
  (hpON); by c16+ it plateaus at ~0.15-0.18x (hpOFF) / ~0.11-0.14x (hpON). OSv NEVER reaches
  80% of Linux RO at any c>1.
- RW: closer but still short. c1 = parity (1.02x hpOFF). Falls below 80% by c8 (0.59x). Best
  mid/high-c RW ratio ~0.40-0.46x. RW ratio is 2-3x better than RO because Linux's own RW
  throughput is far lower than its RO (fsync-bound), so the process-per-connection tax is
  proportionally smaller against a slower baseline.

WHERE THE 80% LINE FALLS: at c=1 only. For every c>=8, on ZFS, OSv is <=0.59x (RW) / <=0.34x
(RO). This is the (already-characterized) process-per-connection tail: Linux async/epoll does
the wake handoff inline in softirq with ~0 per-request thread wakes and scales RO to ~140k;
OSv's forked-backend model peaks at ~vCPU-count (RO ~25k at c8-16) then holds a flat plateau.
The ZFS ratios are LOWER than the prior RAM-vs-RAM ratios (RAM-vs-RAM RO c8 was ~0.88x) because
on ZFS Linux's ARC + async I/O let it scale RO to 140k (vs ramfs ~145k) while OSv-on-ZFS RO
PEAKS at ~25k (ZFS read path through OSv's OpenZFS is much heavier per-query than ramfs, and it
does not scale past ~vCPU-count). So on the REAL deployment substrate (ZFS) the parity gap is
WIDER than the RAM-vs-RAM headline suggested. RW is the relatively stronger cell (0.36-0.46x).

### Does hugepages help OSv more/less than Linux?
Hugepages HURT OSv and are NEUTRAL-to-slightly-helpful for Linux — the OPPOSITE of the hoped-for
"hugepages lift OSv toward parity":
- OSv RO: hugepages COST ~24-27% (c8 24627->18682, c64 21238->15404). OSv's PG shared_buffers on
  2MB pages + qemu -mem-prealloc on hugetlbfs REDUCES RO throughput. Likely OSv's memory
  management / ZFS-ARC interaction pays more for the 2MB-page-backed guest arena than it saves in
  TLB pressure at this working-set size (shared_buffers only 128MB; the RO win from fewer TLB
  misses is small, while prealloc + large-page allocation overhead in OSv's mmu is real).
- OSv RW: hugepages essentially NEUTRAL (within noise, c32 4654->4480).
- Linux RO: NEUTRAL (c32 141512->144094, within noise).
- Linux RW: SMALL LIFT (+11-13% at c32-c64).
=> Net effect on the OSv/Linux RATIO: hugepages make the gap WORSE for OSv at every c (RO ratio
   c32 0.16->0.12; RW ratio c32 0.40->0.34), because they cost OSv RO throughput while giving
   Linux a small RW boost. RECOMMENDATION: run OSv PG-on-ZFS with huge_pages=OFF; the OSv
   hugepage path for the shared-mem arena is a net loss here, not a lever toward parity.

### Verdict summary
On the FIRST real ZFS-vs-ZFS matrix cell (the milestone-1 deployment substrate), OSv is at
parity ONLY at c1 and does NOT meet the >=80% target at any concurrency above 1. The RO gap on
ZFS (~0.15x plateau c16-64) is wider than the RAM-vs-RAM story implied, driven by OSv-OpenZFS's
heavy per-query read path (RO peaks ~25k, does not scale) vs Linux's ARC+async scaling to ~140k.
RW is the stronger cell (~0.4x mid/high-c). Hugepages are a net negative for OSv here. The gap is
the structural process-per-connection floor, now measured on the real ZFS substrate — a legitimate
characterization, not a missing fix. The c64 RW sweep-accumulation fd-wedge (pipe() EMFILE) is a
separate real OSv-on-ZFS ceiling under sustained high-c RW (fresh boot serves c64 RW fine).

============================================================================
## CLEANUP (0 orphans confirmed)
============================================================================
Instance i-073904e1def952353 (osv-zfsq-mtx-host) TERMINATED; root vol
vol-0a3e739524fb73bac auto-deleted (DeleteOnTermination=true, InvalidVolume.NotFound
confirmed). Local NVMe (nvme0/1/3/4 = build scratch + ZFS pool raw files) were
instance-store -> vanished on termination. No AMIs, no snapshots created. All docker
containers (osvqemu/linqemu/pgdriver) + qemu + dnsmasq reaped before terminate.
FINAL SCAN: 0 osv-zfsq instances/volumes/AMIs/snapshots. SG sg-0410 UNMODIFIED (no
0.0.0.0/0). Did NOT touch solnix-*/osv-arm-* (other agents).
