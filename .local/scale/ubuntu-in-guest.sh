#!/bin/bash
# Runs INSIDE the Ubuntu guest (sudo). Installs ZFS (zfsutils-linux) + PG18 (PGDG, io_uring),
# loads zfs with arc_max=2GiB (MATCHED to OSv MEASURED arc_c=2047MB; OSV_ZFS_ARC_MAX absent on this base), creates the MATCHED pool on the raw NVMe (/dev/vdc), initdb.
set -x
exec > /tmp/ubuntu-setup.log 2>&1
echo "=== START $(date) ==="
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -y 2>&1 | tail -2
# ZFS userspace + module (Ubuntu ships DKMS-free zfs for the generic kernel)
sudo apt-get install -y zfsutils-linux 2>&1 | tail -3
echo "APT_ZFS_RC=$?"
sudo modprobe zfs 2>&1; echo "MODPROBE_RC=$?"
zfs version 2>&1 | head -2

# PG18 from PGDG (has io_uring built in for PG18)
sudo apt-get install -y curl ca-certificates gnupg lsb-release 2>&1 | tail -1
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc 2>&1 | tail -1
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update -y 2>&1 | tail -2
sudo apt-get install -y postgresql-18 2>&1 | tail -4
echo "APT_PG_RC=$?"

PGBIN=$(ls -d /usr/lib/postgresql/18/bin 2>/dev/null || echo /usr/lib/postgresql/18/bin)
echo "PGBIN=$PGBIN"
"$PGBIN/postgres" --version 2>&1

echo "=== io_uring support in Ubuntu/PGDG PG18? ==="
"$PGBIN/pg_config" --configure 2>/dev/null | tr ' ' '\n' | grep -iE 'uring' && echo URING_IN_CONFIGURE || echo NO_URING_IN_CONFIGURE
ldd "$PGBIN/postgres" 2>/dev/null | grep -i uring || echo NO_DYNAMIC_URING
dpkg -l | grep -i liburing | head

echo "=== zfs arc_max=32 GiB ==="
echo "options zfs zfs_arc_max=34359738368" | sudo tee /etc/modprobe.d/zfs.conf
echo 34359738368 | sudo tee /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null
sudo rmmod zfs 2>/dev/null; sudo modprobe zfs zfs_arc_max=34359738368 2>&1; echo "REMOD_RC=$?"
cat /sys/module/zfs/parameters/zfs_arc_max 2>&1

echo "=== MATCHED pool on the raw NVMe /dev/vdc ==="
# DEVICE-IDENTITY ASSERTION (an earlier run of this script wiped the OTHER arm's pool):
# boot-ubuntu.sh MUST attach the LINUX device (nvme3n1) as vdc. If vdc is absent or the
# wrong size, REFUSE to run the destructive zpool create rather than scan for a candidate --
# the old fallback loop is exactly what destroyed the OSv arm's seeded pool.
POOLDEV=/dev/vdc
if [ ! -b "$POOLDEV" ]; then
  echo "FATAL: $POOLDEV absent -- boot-ubuntu.sh must attach the Linux pool device as vdc"
  exit 1
fi
SZ=$(sudo blockdev --getsize64 "$POOLDEV")
if [ "$SZ" -lt 500000000000 ]; then
  echo "FATAL: $POOLDEV size=$SZ is not the 838GiB instance-store device; refusing to create"
  exit 1
fi
echo "POOLDEV=$POOLDEV size=$SZ (asserted)"
sudo zpool destroy -f pgdata 2>/dev/null
sudo wipefs -a "$POOLDEV" 2>/dev/null
sudo zpool labelclear -f "$POOLDEV" 2>/dev/null
sudo zpool create -f -o ashift=12 -O recordsize=8k -O compression=off -O atime=off \
  -O sync=standard -O logbias=latency -O primarycache=all -O mountpoint=/data pgdata "$POOLDEV" 2>&1
echo "ZPOOL_CREATE_RC=$?"
sudo zpool get ashift pgdata 2>&1
sudo zfs get recordsize,compression,atime,sync,logbias,primarycache,mountpoint pgdata 2>&1

echo "=== initdb (locale C, trust hba) ==="
sudo mkdir -p /data/pg
sudo chown -R postgres /data
sudo -u postgres "$PGBIN/initdb" -D /data/pg -U postgres --locale=C --encoding=UTF8 -A trust 2>&1 | tail -6
echo "INITDB_RC=$?"
echo "host all all 0.0.0.0/0 trust" | sudo tee -a /data/pg/pg_hba.conf
echo "listen_addresses='*'" | sudo tee -a /data/pg/postgresql.conf
echo "PGBIN=$PGBIN" | sudo tee /tmp/pgbin.env
echo "=== END $(date) ==="
echo UBUNTU_SETUP_DONE
