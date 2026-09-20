#!/bin/sh
# Runs INSIDE the Alpine guest. Switch to edge, install PG 18.6 (musl) + OpenZFS 2.4.4,
# load zfs with arc_max=32GiB, create the MATCHED pool on the NVMe-backed vdb, initdb.
set -x
exec > /tmp/linux-setup.log 2>&1
echo "=== START $(date) ==="

# 1. Repo strategy: zfs from STABLE 3.21 (kernel-matched to the running 6.12.8-0-virt),
# pg18 from EDGE (18.6 is only in edge). zfs 2.2.x completion path == 2.4.x (verified prior).
cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/v3.21/main
https://dl-cdn.alpinelinux.org/alpine/v3.21/community
@edge https://dl-cdn.alpinelinux.org/alpine/edge/main
@edgecomm https://dl-cdn.alpinelinux.org/alpine/edge/community
EOF
apk update 2>&1 | tail -3

# 2. zfs (stable, kernel-matched) + PG 18.6 (edge). zfs flavour matches kernel suffix.
KFLAV=$(uname -r | sed 's/.*-//')
echo "KFLAV=$KFLAV"
apk add zfs zfs-openrc zfs-$KFLAV 2>&1 | tail -6
echo "APK_ADD_ZFS_RC=$?"
apk add postgresql18@edgecomm postgresql18-client@edgecomm postgresql18-contrib@edgecomm 2>&1 | tail -8
echo "APK_ADD_PG_RC=$?"
psql --version 2>&1 || /usr/libexec/postgresql18/psql --version 2>&1
which postgres initdb pg_ctl 2>&1
ls /usr/libexec/postgresql18/ 2>&1 | head

echo "=== 3. load zfs module with arc_max=32 GiB (34359738368) ==="
echo "options zfs zfs_arc_max=34359738368" > /etc/modprobe.d/zfs.conf
modprobe zfs zfs_arc_max=34359738368 2>&1
echo "MODPROBE_RC=$?"
cat /sys/module/zfs/parameters/zfs_arc_max 2>&1
lsmod | grep zfs 2>&1

echo "=== 4. create MATCHED pool on vdb (the NVMe-backed raw file) ==="
# identify the pool disk: the 600G virtio-blk (NOT the ~20G root vda)
POOLDEV=""
for d in /dev/vdb /dev/vdc /dev/vdd; do
  [ -b "$d" ] || continue
  SZ=$(blockdev --getsize64 "$d" 2>/dev/null || echo 0)
  if [ "$SZ" -gt 500000000000 ]; then POOLDEV=$d; break; fi
done
echo "POOLDEV=$POOLDEV"
zpool destroy -f pgdata 2>/dev/null
wipefs -a "$POOLDEV" 2>/dev/null
zpool labelclear -f "$POOLDEV" 2>/dev/null
# IDENTICAL geometry to the OSv arm
zpool create -f -o ashift=12 -O recordsize=8k -O compression=off -O atime=off \
  -O sync=standard -O logbias=latency -O primarycache=all -O mountpoint=/data pgdata "$POOLDEV" 2>&1
echo "ZPOOL_CREATE_RC=$?"
zpool get ashift pgdata 2>&1
zfs get recordsize,compression,atime,sync,logbias,primarycache,mountpoint pgdata 2>&1

echo "=== 5. initdb (musl PG), locale C, trust hba on the driver subnet ==="
INITDB=$(command -v initdb || echo /usr/libexec/postgresql18/initdb)
for c in initdb /usr/libexec/postgresql18/initdb /usr/libexec/postgresql/initdb; do [ -x "$c" ] && INITDB=$c && break; done
echo "INITDB=$INITDB"
PGBIN=$(dirname "$INITDB")
mkdir -p /data/pg
adduser -D -H postgres 2>/dev/null || true
chown -R postgres /data
su postgres -s /bin/sh -c "$INITDB -D /data/pg -U postgres --locale=C --encoding=UTF8 -A trust" 2>&1 | tail -8
echo "INITDB_RC=$?"
cat >> /data/pg/pg_hba.conf <<EOF
host all all 0.0.0.0/0 trust
EOF
echo "listen_addresses='*'" >> /data/pg/postgresql.conf
echo "=== PGBIN=$PGBIN ==="
echo "=== END $(date) ==="
echo LINUX_SETUP_DONE
