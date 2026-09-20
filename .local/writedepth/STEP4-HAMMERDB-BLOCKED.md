# STEP 4 HammerDB verdict: BLOCKED by the PG-guest seed substrate (NOT run)

## What happened
The isolate (STEP 1-3) ran on zfs_builder.elf (the ZFS bench harness image) which booted cleanly and
gave the decisive results.  STEP 4 needs the FULL PG18 rofs image (usr.img) booted as a live PG server,
its ZFS data pool seeded once (seed_copy the baked /data-seed cluster into the pool), then HammerDB
TPROC-C driven from the c5.4xlarge.

The PG18 image built cleanly (114-118MB, postgres in manifest, OSV_IDLE_SPIN in loader.elf).  Networking
(tap0/br0 + DNAT 5432 -> guest) was up.  But the one-time pool SEED failed two ways and could not be
made reliable within budget:
  1. Stock seed_copy (mkdir dst mode = source 0700): every file write into the fresh ZFS dataset
     returned EACCES ("Permission denied") - the guest process could not write files into 0700 dirs it
     had just created on the ZFS mount.  (Seeding into the dataset ROOT /data got deeper - created the
     top dirs - but still EACCES on files inside 0700 subdirs.)
  2. Patched seed_copy (mkdir 0777, open 0666) + re-baked image: the guest now HANGS during seed_copy -
     device write activity starts (~61 MB/s for ~3s) then goes to zero and the guest wedges with no
     console output and no zpool export.  A second attempt showed zero device writes at all.

This is a PG-guest-boot/seed substrate instability on this build, NOT a defect in the OSV_IDLE_SPIN
lever (which lives in the kernel scheduler and is confirmed present in loader.elf).  The prior campaign's
m1confirm/a2a3lever runs seeded PG on ZFS successfully, so the path CAN work; reproducing it reliably
needed more than the remaining budget after the earlier substrate fights (root-owned submodule files
breaking patch re-apply; the missing apps/postgres18-musl submodule at pin 5cb1903; the wrong openzfs
pin causing zfs_file_t; the drifted 0032 patch).

## Consequence for the verdict (stated straight)
The M1 HammerDB transfer of the OSV_IDLE_SPIN recycle lever is UNVERIFIED.  The isolate win is real and
large for pure durable-write concurrency (syncwrite: +56-140% op/s, OSv reaches/exceeds Linux), and the
lever is on every WAL commit's fdatasync critical path so it PLAUSIBLY transfers - but the risk the
parent flagged (idle-spin stealing query cycles from TPROC-C's mixed workload, or ZIL-recycle latency
not being TPROC-C's binding constraint at 200wh) is NOT settled by the isolate and was NOT measured.
Do NOT read the isolate win as "M1 closed."  It closes the durable-write microbenchmark; the TPROC-C
verdict + spin-sweep + vCPU-util discriminator remain to be run on a stable PG-guest seed.

## To finish next run (fast, the analysis is done):
- Fix the seed once: either run PG data on a ramfs-over-ZFS-less path is wrong (must be ZFS); the clean
  fix is to make seed_copy chmod the created dirs to 0777 AFTER populating, or create the pool dataset
  with a world-writable root, and confirm the guest completes the ~40MB copy + zpool export.  Then the
  hdb-verdict.sh harness (already written: spins=10000/100000/500000 x VU=16/32, mpstat vCPU sampling)
  runs the verdict directly.
