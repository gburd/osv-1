# The geometry/libc-matched Linux baseline: three confounds I had missed

2026-09-08, agent 7d0737f3. All three found before the run, all verified by me.

## 1. "32 physical cores on one socket" is arithmetically impossible on m5d.metal
    m5d.metal = 2 sockets x 24 physical x 2 threads = 96 logical
    one socket holds 24 physical cores

So my "prefer physical cores" instruction could not be satisfied. The options:

    (a) 32 logical = 16 physical x 2 HT, node 0 (cpus 0-15,48-63)  -> one socket, count matches  CHOSEN
    (b) 32 physical = 24 from node0 + 8 from node1                 -> cross-socket confound      rejected
    (c) 24 physical, one socket                                    -> wrong count (24 != 32)     rejected

Taking (a) with `cpuset.cpus=0-15,48-63`, `cpuset.mems=0`, and reporting it as
"**32 logical CPUs = 16 physical cores x 2 hyperthreads, socket 0**" rather than "32 cores". The
agent verified the sibling pairs (0/48, 1/49, 15/63) instead of assuming the topology.

## 2. The memory-cap MECHANISM (already banked): kernel `mem=` needs a reboot and would cap the
other tasks sharing the box. cgroup v2 is both cheaper and the closer analogue to a guest, which
sees a hard ceiling rather than a smaller machine.

## 3. THE ARC HOLE - the one that would have invalidated the whole comparison

A cgroup `MemoryMax` charges **PostgreSQL**. **ZFS ARC lives in host kernel memory and is NOT
charged to the cgroup.** On a 384 GiB box that gives Linux an ARC of up to **~377 GiB** against the
OSv guest's **64 GiB total** - a cache roughly **5.9x the entire guest**. The dataset is only ~19 GB,
so **Linux would have run essentially fully cached** while OSv paged against a 16 GB ARC inside
64 GiB.

I would have published that as a platform result. It is the same shape as every other silent-success
trap in this project: the configuration *looks* matched, the numbers come out clean, and the
comparison is meaningless.

Fix: `zfs_arc_max=16G`, with the residual (~80 GiB host-side commitment vs the guest's 64 GiB,
favouring Linux slightly) **reported rather than hidden**.

Refinements I added, both following the same rule as the memory cap - a limit that is set but never
binds proves nothing:
- **Prove `zfs_arc_max` bound**: `cat /sys/module/zfs/parameters/zfs_arc_max` plus ARC
  `size`/`c`/`c_max` from `/proc/spl/kstat/zfs/arcstats` **during** the run, not just the setting.
- **State the ARC comparison explicitly**: Linux 16 GiB ceiling vs the OSv guest's ARC, which our
  patch 0031 caps at half of guest RAM (~32 GiB of 64). If they differ, say which way it cuts rather
  than leaving them silently unequal.

## musl via Alpine container, with two things to confirm
Building AND running PG 18.6 inside an **Alpine container** (`--cpuset-cpus=0-15,48-63
--cpuset-mems=0 --memory=64g`, ZFS dataset bind-mounted) gets genuine musl userspace with no
cross-toolchain fragility, and the same cgroup-v2 mechanism applies the limits so the geometry proof
is unaffected. Asked to confirm:
- **no overlayfs between PG and the dataset** - bind-mount straight onto it, and paste `mount` from
  inside the container showing `zfs`, not `overlay`;
- the PG is **our** `REL_18_STABLE` build with our configure line, **not Alpine's packaged postgres**.
Plus `ldd`, the musl interpreter from `readelf -l`, and `select version()`.

## Running tally on this task
Fourth premise of mine corrected by this one agent: the loader/qemu path, the geometry, the
memory-cap mechanism, and the ARC hole. The ARC one is the difference between a real comparison and
a flattering one.

## 4. `free -g` inside a cgroup does NOT prove the memory cap (my brief asked for exactly that)

Measured from inside the constrained container:

    nproc            : 32     <- correct, cpuset IS reflected
    free -g total    : 378    <- WRONG, shows the whole host

`free(1)` reads `/proc/meminfo`, which is **not namespaced by cgroups** without lxcfs. So my
requested proof would have reported 378 GiB and looked like the cap had FAILED when it had not - a
false negative that could have sent the agent rebuilding a working setup.

Authoritative proof is the cgroup files:

    memory.max            = 68719476736  = 64.00 GiB exactly
    cpuset.cpus.effective = 0-15,48-63   = 32 logical (16 phys x 2 HT), socket 0
    cpuset.mems.effective = 0            = socket-0 memory only
    memory.peak           = 399880192    = 381 MiB at idle, pre-load

**This is the third instrument-not-code false signal in this campaign**, after `msync` reporting a
correctly-mapped private library segment as unmapped, and `echo` swallowing a failed `git push`.
Standing lesson reinforced: **choose an instrument whose failure mode you understand; the instrument
lies more often than the code.**

## The cap will probably NOT bind, and that is a finding rather than a caveat

`shared_buffers=16G` + ~20G shm is ~36 GiB of anonymous commitment against a 64 GiB ceiling, and the
19 GB dataset lands in page cache/ARC rather than anon. So the honest statement is **"geometry
matched, but memory was not the binding constraint on either side"** - which is *more* useful than a
bound cap, because it rules out memory pressure as an explanation for the OSv-vs-Linux gap on either
side. Asked for `memory.peak` after the sweep so the claim is measured, not predicted.

## Confounds now closed, with proof
- **No overlayfs in the data path**: `pgdata on /data/pg type zfs` while `/` is overlay.
- **Our PG, not Alpine's**: `REL_18_STABLE` @ `5d63dbd9774dcb28d7c88bfce42505376b201861`, runtime
  image has only `libgcc` added; Alpine's postgres package was never installed.
- **musl confirmed EXTERNALLY** from the driver: `select version()` ->
  `PostgreSQL 18.6 on x86_64-pc-linux-musl`.

## Residuals to state, not chase
- **gcc 13.3.1 (Fedora, OSv arm) vs 13.2.1 (Alpine, Linux arm)** - same musl triplet, same configure
  line, same CFLAGS. A patch-level gcc difference is far smaller than the glibc-vs-musl and
  16-vs-32-vCPU gaps just eliminated; matching it exactly would be false precision.
- **ARC ceilings**: Linux `zfs_arc_max=16G` vs the OSv guest's ARC, capped by patch 0031 at half of
  guest RAM (~32 GiB of 64). Asked for this to be stated with which way it cuts - the last
  asymmetry I can identify in this comparison.
