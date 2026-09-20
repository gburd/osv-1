#!/bin/bash
# Runs INSIDE the Ubuntu guest (sudo). Installs ZFS (zfsutils-linux) + PG18 (PGDG, io_uring),
# loads zfs with arc_max=32GiB, creates the MATCHED pool on the raw NVMe (/dev/vdc), initdb.
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
POOLDEV=/dev/vdc
[ -b "$POOLDEV" ] || { for d in /dev/vdb /dev/vdc /dev/vdd; do [ -b "$d" ] && SZ=$(sudo blockdev --getsize64 "$d") && [ "$SZ" -gt 500000000000 ] && POOLDEV=$d && break; done; }
echo "POOLDEV=$POOLDEV size=$(sudo blockdev --getsize64 $POOLDEV)"
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
