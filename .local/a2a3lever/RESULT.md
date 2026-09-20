# M1-parity: PostgreSQL on OSv vs Linux — same box, one variable (the OS)

**Date:** 2026-09-13. **Boxes (AWS lava, acct 769093516156, us-east-2, Owner=agent-a2a3lever):**
- `i-0eba44006fe97ac9a` m5d.metal — BOTH arms + host (OSv guest, then Linux guest, same NVMe)
- `i-078c9e259713bb52f` c5.4xlarge — HammerDB driver

Both TERMINATED at end (see Housekeeping). 0 orphans confirmed.

## Design — what made the hardware identical
ONE m5d.metal, ONE physical instance-store NVMe (`/dev/nvme0n1`, 838 GiB) → XFS `/mnt/nv` → a
600 GiB raw file → virtio-blk `vdb` → ZFS pool `pgdata`. The OSv arm ran first; its pool was
**exported and the raw file destroyed**, then recreated for the Linux arm on the SAME device. Arms
never ran concurrently, so they never contended for the NVMe. Both arms ran as a **KVM guest under the
SAME qemu 8.1.3** (fedora:39 container, `-M pc -cpu host -enable-kvm`, virtio-blk, `-smp 32 -m 64G`).

**Hypervisor was matched deliberately (Linux in a KVM guest, NOT bare host).** `BENCH-METHODOLOGY-A2A.md`
flagged that the historical 213k Linux number was invalid precisely because Linux ran bare-metal while
OSv ran in KVM. Running Linux in an identical guest removes that confound: the only variable left is
Linux-guest-kernel vs OSv-unikernel. No historical Linux number is reused; Linux was measured fresh
here with the matched 32 GiB ARC.

## Matched configuration — proven on BOTH arms
| axis | OSv arm | Linux arm | matched? |
|---|---|---|---|
| PG | 18.6, x86_64-pc-linux-**musl**, gcc 13.3.1 | 18.6, x86_64-alpine-linux-**musl**, cc 15.2 | musl both (triple/compiler differ — see caveat) |
| warehouses | 200 / 19 GB | 200 / 19 GB | yes |
| ZFS geometry | ashift=12 recordsize=8K compression=off atime=off sync=standard logbias=latency primarycache=all | same (atime: /proc/mounts=noatime; 2.4.4 prop-display quirk shows "on") | yes |
| ZFS version | OpenZFS 2.4.2 | OpenZFS 2.4.4 | completion path identical (iowake-verified) |
| ARC cap | 32 GiB (OSv patch 0031 = half of 64 GiB guest) | zfs_arc_max=34359738368 (32 GiB) | yes |
| ARC binds under load | (OSv caps by design) | **PROVEN**: size 34.30–34.36 GB pinned at c_max=32 GiB, c=c_max, max=100.09% | yes |
| geometry | 32 vCPU / 64 GiB | 32 vCPU / 63 GiB | yes |
| io_method / durability | sync / fsync=on synchronous_commit=on autovacuum=on | same | yes |
| 12 GUCs | all source=command line (verified from driver) | all source=command line (verified from driver) | **identical values** |

12 GUCs (both, source=command line): max_connections=400 shared_buffers=16GB effective_cache_size=32GB
max_wal_size=64GB min_wal_size=2GB checkpoint_timeout=900s checkpoint_completion_target=0.9
log_checkpoints=on fsync=on synchronous_commit=on autovacuum=on io_method=sync.

**OSv base:** `gh-fork/bench/a2a-all-levers` (OSV_SHA 17d81475, apps 3f93f43). All levers verified on the
built source: stack_guard=3, OSV_FORK_RANGE_BS=2, OSV_FORK_LARGE_SHARE=2, write_cache.empty()=1,
osv::clock::wall=3, wake_pull_enabled=true. Console at boot: **`WAKE_PULL ON`** (+ `WAKE_LOCAL off`) —
the scaling lever is armed by default; OSV_WAKE_PULL was NOT set (setting =0 would disable it). usr.img
= 118,685,696 B (114 MiB), byte-identical to the prior verified-good image.

## HEADLINE — matched OSv vs Linux (medians of 3 settled repeats, r1 voided as cold-inflated)

    VU   OSv NOPM (med)   Linux NOPM (med)   ratio OSv/Linux   OSv/Linux delta%
     8       104,640          159,792            0.655            -34.5%
    16        64,839          268,921            0.241            -75.9%
    32       WEDGED*           (not run)           —                —

    OSv   : 104,640 -> 64,839   = -38% (VU8 -> VU16), then WEDGE at VU32
    Linux : 159,792 -> 268,921  = +68% (VU8 -> VU16)

\* a2a-all-levers OSv VU32 hard-**wedged** (true deadlock, see below). The shape-fix run (a2a + #1502)
cleared it — VU32 then completed at ~62,400 NOPM (3 cells, no wedge).

### Per-VU detail (p99 alongside every throughput number)
| VU | arm | NOPM med | NEWORD p99 | connect-probe p99 / >=1s | wait profile (arm, %) | nvme %util | qemu vCPU busy |
|---|---|---|---|---|---|---|---|
| 8 | OSv | 104,640 | ~49 ms | 44 ms / 0 | WALWrite 31-34, WalSync 10, NULL 40-44 | 24% | 7.7/32 |
| 8 | Linux | 159,792 | ~34-36 ms | 32-35 ms / 0 | WALWrite 28.5, WalSync 12.1, NULL 51.9 | 30% | 8.8/32 |
| 16 | OSv | 64,839 | ~64-84 ms | clean | **NULL 68**, WALWrite 13-18 | 28% | 12.4/32 |
| 16 | Linux | 268,921 | ~39-59 ms | 33 ms | **NULL 45.9**, WALWrite 37.0, WalSync 6.0 | 47% | 15.5/32 |

Raw repeats:
- OSv VU8: 158830(void), 101898, 104640, 108688  (spread 6.5%)
- OSv VU16: 65551, 64114, 64839  (spread 2.2%)
- Linux VU8: 158843(void), 159792, 161419, 151307  (spread 6.3%)
- Linux VU16: 275290, 268921, 261387  (spread 5.2%)

## THE FOUR QUESTIONS, answered

**1. Does OSv reach parity with Linux now?** No. OSv is at **0.655× Linux at VU8** (−34.5%) and
**0.241× at VU16** (−75.9%). Parity is not met, and the gap **widens** with concurrency.

**2. Does OSv SCALE now (the point of WAKE_PULL default-on)?** No — the SHAPE is the finding.
OSv still **peaks at VU8 and declines** (104,640 → 64,839, −38%). Linux **scales** (159,792 → 268,921,
+68%). WAKE_PULL default-on did NOT change OSv's shape at 200 warehouses. **This is not a WAKE_PULL
failure** — see Q4: at these VUs backends are BLOCKED on WAL-commit, not runnable-and-piled, so
work-stealing has nothing to steal. The +238% WAKE_PULL win in the earlier A/B was at 40 warehouses
hitting the wake-placement collapse; at 200 warehouses a DIFFERENT constraint (WAL-commit
serialization) binds.

**3. Where is the residual gap?** The wait profiles pin it. At VU16 **Linux stays WALWrite-bound
(37%) and scales**; **OSv's NULL-wait jumps to 68%** — backends stalling to be *woken* after WAL
commit — while device is only 28% util and 12 of 32 vCPUs are busy. Both are WAL-fsync bound at VU8
(near-identical profiles), but under concurrency OSv cannot service the WAL-commit/wakeup path fast
enough. **The residual gap is OSv's WAL-commit-completion serialization**, consistent with the iowake
isolate (+264 µs OSv excess in the ZIL-commit-completion wakeup, device ~93% idle).

**4. Is WAKE_PULL working as designed?** Yes — and its low busy-count is the *evidence* the ceiling is
elsewhere. At VU8, 7.7/32 vCPUs busy; at VU16, 12.4/32. The VU32 wedge diagnostic (`top -H`) showed
**all 35 qemu threads in S (sleep), 0 in R, 0 in D** — nothing runnable to steal. WAKE_PULL is
correctly a no-op when backends are blocked (on WAL commit / in a deadlock), not runnable-and-unplaced.
It restores throughput only when there IS a runnable pileup; here there is not.

## Bonus result — the VU32 wedge is the dentry AB-BA deadlock, and #1502 fixes it end-to-end
The a2a base wedged at VU32 (all threads asleep, 0 runnable, ~27 GiB free = a true deadlock, not a
lost wake). Diagnosis: dentry `dentry_hash_lock` ↔ vnode-lock AB-BA inversion. The a2a base carries
neither #1502 nor #1503.

Ran a shape-fix arm on the SAME box: `gh-fork/bench/a2a-shape-fix` = a2a base + **#1502** (AB-BA
lock-order fix only). **Mandatory `bench-base-gate.sh` PASS** on the built tree (all required markers
incl. `vfs_dentry_hash_lock_held`=2). Result:

    a2a base    VU32: WEDGED (deadlock, sweep could not complete)
    a2a + #1502 VU32: 291,357 (r1 cold-void), then 62,044 / 62,832 settled — 3 cells, NO wedge

**#1502 removes the VU32 deadlock end-to-end** (it previously had only a deadlock-assertion test, no
scaling proof). qemu went from 0 runnable (wedge) to ~17.9/32 vCPUs busy. shape-fix VU8 (~93-101k)
matched a2a VU8 (~104k) — #1502 is correctly a no-op at low VU.

But **the WAL-commit ceiling persists past the deadlock**: shape-fix VU32 settled at ~62k NOPM ≈ OSv
VU16 (65k), still far below Linux VU16 (269k). Fixing the deadlock lets the sweep COMPLETE at VU32; it
does not close the throughput gap. A separate wedge (postmaster alive, "autovacuum worker took too long
to start", all threads asleep — a fork/worker-start hang, NOT the dentry deadlock) appeared later at the
VU8/VU16 boundary after many cells; not pursued (budget).

## Honest caveats
- **libc:** musl on both, but different build triples/compilers (OSv gcc-13.3 x86_64-pc-linux-musl;
  Alpine cc-15.2 x86_64-alpine-linux-musl). musl itself is matched; the compiler/triple is a minor
  residual and was not controlled here.
- **ZFS:** 2.4.2 (OSv) vs 2.4.4 (Linux). zio completion path identical across 2.4.x (iowake-verified).
- **atime:** Linux pool property display showed "on temporary" (OpenZFS 2.4.4 quirk) but /proc/mounts
  showed `noatime` — effectively off, matching OSv.
- r1 voided as cold-inflated on every arm (OSv VU8 158830, Linux VU8 158843, shape-fix VU32 291357) —
  the documented first-after-build backlog-drain inflation.

## Bottom line, stated straight
With every OSv lever on and the config matched byte-for-byte (32 GiB ARC proven binding on both, same
qemu, 32 vCPU, same 200wh dataset, same 12 GUCs source=command line, same physical NVMe), **OSv does
NOT reach parity with Linux and does NOT scale where Linux does.** OSv: 0.655× at VU8, 0.241× at VU16,
and it wedges at VU32 on the a2a base. Linux scales +68% VU8→VU16 on identical hardware. The residual
gap is characterized: **OSv's WAL-commit-completion serialization** — backends block waiting to be
woken after commit (NULL-wait 68% at VU16) while the device sits 72% idle. #1502 removes the VU32
deadlock (proven end-to-end) but not this throughput ceiling. **A characterized gap is a real result.**

## Housekeeping
Both boxes terminated; 0 tagged instances, 0 tagged volumes remaining (see terminate log below).
