#!/bin/bash
# Build the OSv-native RUN image: create a PRISTINE ZFS pool on the RAW LOCAL
# NVMe, seed PGDATA onto it, start PostgreSQL 18.6.  ONE boot chain, so a
# per-cell fresh boot = an instance REBOOT (instance-store survives a reboot;
# it is lost on stop, which is why the chain must not end).
#
# DEVICE MAP measured on the probe boot: vblk0=EBS root, vblk1/vblk2=local NVMe.
# The pool goes on RAW /dev/vblk1 -- matched to the Linux arm's raw /dev/nvme1n1.
#
# ARGS: <suffix> [extra boot env, e.g. --env=OSV_IDLE_SPIN=1]
set -uo pipefail
. /home/gburd/ws/osv/.local/projmax/env.sh
SUF="${1:-run}"
EXTRA="${2:-}"

# ZFS geometry -- matched to the Linux arm character for character.
ZPOOL="/zpool.so create -f -o ashift=12 -O recordsize=8k -O compression=off -O atime=off -O sync=standard -O logbias=latency -O primarycache=all -O mountpoint=/data pgdata /dev/vblk1"
# GUCs -- the SAME set is applied to the Linux arm, and both are read back from
# the running server with pg_settings (pasted per arm in RESULT.md).
PGARGS="-c listen_addresses=* -c max_connections=400 -c shared_buffers=16GB -c effective_cache_size=48GB -c max_wal_size=32GB -c min_wal_size=2GB -c checkpoint_timeout=15min -c checkpoint_completion_target=0.9 -c fsync=on -c synchronous_commit=on -c autovacuum=on -c io_method=sync -c max_files_per_process=200"
CMD="$ZPOOL ; /zpool.so get ashift pgdata ; /zfs.so get recordsize,sync,compression,atime,logbias,primarycache pgdata ; /usr/bin/seed_copy /data-seed /data/pg ; /usr/bin/postgres -D /data/pg $PGARGS"
# LEVERS, every one self-printing to the console (the standing rule):
#   WAKE_PULL   -> printf "WAKE_PULL ON|off"
#   BLK_MQ      -> printf the completion mode + queue count (virtio-blk only;
#                  this native box uses NVMe, so it is reported as inert)
#   FORKARENA   -> debug_early "FORKARENA ovf_recycle=" (compile-time arm)
#   RNGPROOF    -> printf rdrand/rdseed/hwsrc_empty/seeded
#   ARCPROBE    -> printf arc_size/arc_c/arc_c_max every 10s (MEASURED, not asserted)
BOOT="--console=serial --preload-zfs-library --nomount --env=OSV_WAKE_PULL=1 --env=OSV_FP_INTERVAL=30 $EXTRA"
exec bash "$PM/mkami-local.sh" "$SUF" "$BOOT $CMD"
