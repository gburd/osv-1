#!/bin/bash
# Build the OSv-native RUN image for bench24: create a PRISTINE ZFS pool on the
# RAW LOCAL NVMe, seed PGDATA onto it, start PostgreSQL 18 with the matched GUCs.
#
# *** io_method=worker ON BOTH ARMS -- declared deviation from the io_uring
# directive; see RESULT.md section 2.  io_uring is NOT compiled into this PG
# (no --with-liburing in apps@3f93f43), so requesting it would make the
# postmaster refuse to start.  worker is a real async path present in both
# existing builds and keeps the image identical to the preflight-validated one.
#
# DEVICE MAP on native Nitro: vblk0=EBS root, vblk1/vblk2=local NVMe.  The pool
# goes on RAW /dev/vblk1 -- matched to the Linux arm's raw instance-store NVMe.
#
# ARGS: <suffix> [extra boot env]
set -uo pipefail
. /home/gburd/ws/osv/.local/bench24/env.sh
SUF="${1:-run}"
EXTRA="${2:-}"

# ZFS geometry -- matched to the Linux arm character for character.
ZPOOL="/zpool.so create -f -o ashift=12 -O recordsize=8k -O compression=off -O atime=off -O sync=standard -O logbias=latency -O primarycache=all -O mountpoint=/data pgdata /dev/vblk1"
# GUCs -- the SAME set the Linux arm gets, byte-identical, read back per arm.
PGARGS="-c listen_addresses=* -c max_connections=400 -c shared_buffers=16GB -c effective_cache_size=48GB -c max_wal_size=32GB -c min_wal_size=2GB -c checkpoint_timeout=15min -c checkpoint_completion_target=0.9 -c fsync=on -c synchronous_commit=on -c autovacuum=on -c io_method=worker -c io_workers=3 -c max_files_per_process=200"
# NOTE: `zfs get ashift` is INVALID (ashift is a zpool property) and its usage
# dump HALTS the rest of an OSv boot command chain, presenting as "PG never
# started".  That cost one AMI rebuild on a prior run; ashift is read with
# zpool.so get, everything else with zfs.so get.
CMD="$ZPOOL ; /zpool.so get ashift pgdata ; /zfs.so get recordsize,sync,compression,atime,logbias,primarycache pgdata ; /usr/bin/seed_copy /data-seed /data/pg ; /usr/bin/postgres -D /data/pg $PGARGS"
# LEVERS, each self-printing to the console (printf, never debugf):
#   WAKE_PULL       #1472 wake-pull resolved state
#   RNGPROOF        rdrand/rdseed/hwsrc_empty/seeded
#   IDLE_SPIN_PROOF #1511 adaptive/cap/floor/shrink_after
#   SCHEDPROBE      per-CPU busy% + agg_busy_vcpu + n_ge50/n_le5 + MTXPROBE
#   ARCPROBE        arc_size/arc_c/arc_c_max MEASURED every 10s
#   NONROTPROBE     #1513 EFFECT: req_total / req_gt128KiB / max_KiB
BOOT="--console=serial --preload-zfs-library --nomount --env=OSV_WAKE_PULL=1 --env=OSV_SCHEDPROBE_INTERVAL=10 $EXTRA"
exec bash "$NB/mkami-local.sh" "$SUF" "$BOOT $CMD"
