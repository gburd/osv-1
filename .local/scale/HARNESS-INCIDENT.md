# Harness incident: the Linux arm's pool creation DESTROYED the OSv seed (my bug, not OSv's)

## What happened
I decided to give each arm its own dedicated NVMe (OSv=nvme1n1, Linux=nvme3n1) so the two
pools could coexist and the arms could be INTERLEAVED (killing the run-order confound).
The device split was correct and measured (fio: 100.4k vs 100.8k IOPS, 0.4% apart).

But I ran `ubuntu-in-guest.sh` BEFORE I edited `boot-ubuntu.sh` to pass nvme3n1. At that
moment the Ubuntu guest still received **nvme1n1** as its `vdc`, and its setup script does:
```
sudo zpool destroy -f pgdata; sudo wipefs -a "$POOLDEV"; sudo zpool labelclear -f "$POOLDEV"
sudo zpool create -f ... pgdata "$POOLDEV"
```
so it wiped OSv's seeded pool and built the Linux pool on OSv's device. The OSv arm then
booted, imported the pool that was there, and PG correctly refused:
`FATAL: data directory "/data/pg" has wrong ownership` (the dir was postgres-owned by the
Linux initdb, while OSv's postgres runs as uid 0).

The telltale that identified it: OSv reported `pgdata used 39.1G` — the Linux pool's size —
where OSv's own seeded pool is 52M before the schema build. Pool SIZE, not the ownership
error, is what named the real cause; the ownership message was a downstream symptom.
(My fio equivalence test also wrote to both devices, but at offset 100G with no label
damage; the pool destroy is what actually did it.)

## Cost and blast radius
- Lost: the OSv seed + the OSv 200wh schema build (~35 min of wall clock, one rebuild).
- NOT lost: the Linux pool/schema on nvme3n1 was intact and correct throughout (39.1G,
  postgres-owned, ashift=12/recordsize=8k/sync=standard verified) — no Linux rework needed.
- No measurement was taken during the broken window, so NO reported number is affected.
  The failure was loud (PG refused to start) rather than silent, which is why it cost time
  instead of correctness.

## Why it was caught rather than reported as an OSv scaling failure
The cell aborted in `wait for PG` and I read the console instead of retrying. A less careful
reading would have logged "OSv fails to start at VU32" — a fabricated OSv defect from a
harness bug. The rule that saved it: when a cell fails to come up, read the guest console
and check the POOL IDENTITY before concluding anything about the guest.

## Fixes applied
1. `boot-ubuntu.sh` pins the Linux pool device to `/dev/nvme3n1` (done before any real cell).
2. Re-seeded OSv on nvme1n1 after `wipefs` + zeroing the first/last 64MiB (stale labels at
   the device tail are why a bare `wipefs` is not sufficient for ZFS).
3. Seeding requires TWO boots: one `zpool create`, then a SEPARATE `import -N && mount &&
   seed_copy` boot. In a single boot the create-then-seed chain copied nothing (pool stayed
   420K) because `zfs list` printed `(null)` — the dataset was not ready for the copy in that
   same boot. The two-boot form reliably yields the 52.0M seeded cluster.

## Standing lesson for this scaffolding
When arms share a host, the device assignment must be pinned in EVERY script that touches a
raw device BEFORE any setup runs, and each arm's setup must verify it is operating on its own
device (size/label/pool-name) before a destructive `zpool create`. A dedicated-device layout
is still the right call — it removes the pool rebuild between arms and enables interleaving —
but it needs the device identity asserted, not assumed.

---

# SECOND occurrence, same root cause, and the gate that now prevents it

## It happened AGAIN, and the reason is the important part
After writing the fix above I re-ran the sweep. The Linux VU32 cell reported a plausible
183,565 NOPM — and `iostat` on nvme3n1 showed **literally zero IO** for a durable
(fsync=on, synchronous_commit=on) TPC-C run. That is physically impossible, which is what
exposed it: the Linux guest was running on **nvme1n1 again**, destroying the freshly rebuilt
OSv pool for the second time.

Why, despite "fixing" it: I edited `boot-ubuntu.sh` LOCALLY but never re-`scp`'d it, and the
metal still had the pre-fix copy naming `/dev/nvme1n1`. I had verified the file I edited
instead of **the file the box would actually execute**. The device-identity assertion I added
to `ubuntu-in-guest.sh` did not help either, because it asserts on `vdc` — and `vdc` *was*
present and 838GiB; it was just backed by the wrong host device. The assertion was at the
wrong layer.

Also learned: nvme3n1 had NEVER held the Linux pool. The original `ubuntu-in-guest.sh` run
happened before the device edit, so both the first and second Linux pools were built on
nvme1n1. My earlier note that "the Linux pool on nvme3n1 was intact" was wrong — I inferred
it from `zpool status` showing `vdc` without checking which host device backed `vdc`.

## The number that would have been published
`linux-vu32-r1 NOPM=183565` against `osv-vu32-r1 NOPM=305319` = **OSv 1.66x AHEAD**. It is
VOID: that Linux cell ran on a device it shared with nothing, but with a pool whose data the
OSv arm had built, an unquantified cache/layout state, and it did zero durable IO. Publishing
it would have produced a spectacular and completely false "OSv 1.66x faster than Linux"
headline — the exact error class this campaign already had to retract once.

## What actually catches it (added to sweep.sh, runs before any cell)
1. **SCRIPT-SYNC GATE** — md5sum every harness script on BOTH boxes against the local copy and
   REFUSE to sweep on any mismatch. This is the gate that would have caught both occurrences,
   because both were stale-on-box-copy bugs, not logic bugs.
2. **DEVICE-ASSIGNMENT GATE** — assert `boot-ubuntu.sh` names nvme3n1 and `boot-osv.sh` names
   nvme1n1 before starting.
3. **Zero-IO sanity**: a durable cell with `nvme_util≈0` is not a result, it is a broken cell.
   Worth treating as an automatic invalidation signal alongside the driver-saturation check.

## Cost
Two OSv seed+schema rebuilds and one Linux pool+schema build (~90 min total). No measurement
survived into the report from either broken window; the only casualty is wall clock, and the
VOID cell is documented above rather than deleted.
