#!/bin/bash
# LINUX arm: ZFS pool on the RAW LOCAL NVMe, geometry matched to the OSv arm
# character-for-character, PGDATA seeded, PG18 started with the SAME GUCs.
# Called fresh per cell after a stop/start.
#
# *** io_method=worker ON BOTH ARMS -- A DELIBERATE, DECLARED DEVIATION. ***
# The standing directive is io_uring.  apps@3f93f43 postgres18-musl/build.sh
# configures PG WITHOUT --with-liburing (its own comment at :134-140 says so), so
# USE_LIBURING is undefined and `-c io_method=io_uring` would be REJECTED by the
# postmaster (io_method is PGC_POSTMASTER).  Rebuilding the OSv PG with a musl
# liburing would introduce a THIRD changed variable -- the two arms' PG binaries
# would differ in configure tuple -- which is the class of conflation that got an
# earlier table withdrawn.  worker is a real ASYNC path with dedicated IO worker
# processes, available from BOTH existing builds, and satisfies the directive's
# PURPOSE (stop measuring a synchronous configuration nobody deploys).
# Read back from the running server on both arms; any cell whose readback is not
# `worker` is not quoted.
#
# ARGS: <mode: fresh|start>
set -x
MODE="${1:-fresh}"
# DEVICE DISCOVERY BY MODEL, NOT BY NAME.  Measured the hard way: across a
# stop/start the kernel's nvme enumeration order CHANGES -- /dev/nvme1n1 was the
# local instance store on one boot and the EBS ROOT on the next.  A hardcoded
# pool device nearly wiped a root filesystem.  Select by NVMe model string and
# refuse if the device holds mounted partitions.
POOLDEV=$(lsblk -dn -o NAME,MODEL | awk '/Amazon EC2 NVMe Instance Storage/{print "/dev/"$1; exit}')
if [ -z "$POOLDEV" ]; then echo "FATAL: no local instance-store NVMe found"; exit 1; fi
if lsblk -n -o MOUNTPOINT "$POOLDEV" | grep -q .; then
  echo "FATAL: $POOLDEV has mounted partitions -- refusing (this is how a root disk gets wiped)"; exit 1
fi
echo "POOLDEV_RESOLVED=$POOLDEV ($(lsblk -dn -o SIZE $POOLDEV))"
exec > /tmp/linux-pg-$MODE.log 2>&1
echo "POOLDEV_RESOLVED=$POOLDEV"

PGB=/usr/lib/postgresql/18/bin
PGDATA=/data/pg

if [ "$MODE" = fresh ]; then
  sudo zpool destroy pgdata 2>/dev/null
  sudo zpool labelclear -f $POOLDEV 2>/dev/null
  sudo wipefs -a $POOLDEV 2>/dev/null
  sudo zpool create -f -o ashift=12 \
    -O recordsize=8k -O compression=off -O atime=off -O sync=standard \
    -O logbias=latency -O primarycache=all -O mountpoint=/data pgdata $POOLDEV || exit 1
  sudo zpool get ashift pgdata
  sudo zfs get recordsize,sync,compression,atime,logbias,primarycache pgdata
  sudo mkdir -p $PGDATA && sudo chown postgres:postgres /data $PGDATA && sudo chmod 700 $PGDATA
  sudo -u postgres $PGB/initdb -D $PGDATA -U postgres --locale=C -E UTF8 \
    --auth-local=trust --auth-host=trust || exit 1
  echo "host all all 0.0.0.0/0 trust" | sudo tee -a $PGDATA/pg_hba.conf
  sudo -u postgres sed -i "s/^#*listen_addresses.*/listen_addresses='*'/" $PGDATA/postgresql.conf
fi

# SAME GUCs as the OSv arm, byte-identical list.  io_method=worker on both.
PGARGS="-c listen_addresses=* -c max_connections=400 -c shared_buffers=16GB \
-c effective_cache_size=48GB -c max_wal_size=32GB -c min_wal_size=2GB \
-c checkpoint_timeout=15min -c checkpoint_completion_target=0.9 \
-c fsync=on -c synchronous_commit=on -c autovacuum=on -c io_method=worker \
-c io_workers=3 -c max_files_per_process=200"

sudo -u postgres $PGB/pg_ctl -D $PGDATA -l /tmp/pg.log -o "$PGARGS" -w start || { sudo tail -30 /tmp/pg.log; exit 1; }

echo "=== GUC READBACK FROM THE RUNNING SERVER (not from the command line) ==="
$PGB/psql -h 127.0.0.1 -U postgres -d postgres -Atc \
 "select name||'='||setting from pg_settings where name in
  ('io_method','io_workers','shared_buffers','max_connections','synchronous_commit','fsync',
   'max_wal_size','min_wal_size','wal_level','wal_sync_method','effective_cache_size',
   'checkpoint_timeout','autovacuum','max_files_per_process','data_directory','server_version')
  order by name;"
echo "=== IO WORKER PROCESSES (worker mode forks dedicated IO workers) ==="
ps -eo pid,comm,args | grep -c '[i]o worker'
ps -eo pid,args | grep '[i]o worker'
echo LINUXPG_DONE
