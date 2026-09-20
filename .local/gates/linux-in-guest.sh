#!/bin/sh
# Runs INSIDE the Alpine guest (as root via doas). Installs PG 18.6 (musl) + OpenZFS,
# loads zfs with arc_max=32GiB, creates the MATCHED pool on the raw NVMe (/dev/vdc), initdb.
# Verifies io_uring support (must match the OSv arm's io_method=io_uring).
set -x
exec > /tmp/linux-setup.log 2>&1
echo "=== START $(date) ==="

# repos: zfs from stable 3.21 (kernel-matched), PG18 from edge
cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/v3.21/main
https://dl-cdn.alpinelinux.org/alpine/v3.21/community
@edge https://dl-cdn.alpinelinux.org/alpine/edge/main
@edgecomm https://dl-cdn.alpinelinux.org/alpine/edge/community
EOF
apk update 2>&1 | tail -2

KFLAV=$(uname -r | sed 's/.*-//')
echo "KFLAV=$KFLAV"
apk add zfs zfs-openrc zfs-$KFLAV 2>&1 | tail -4
echo "APK_ZFS_RC=$?"
apk add postgresql18@edgecomm postgresql18-client@edgecomm postgresql18-contrib@edgecomm 2>&1 | tail -6
echo "APK_PG_RC=$?"

PGBIN=/usr/libexec/postgresql18
[ -x "$PGBIN/postgres" ] || PGBIN=$(dirname "$(command -v postgres 2>/dev/null || echo /usr/bin/postgres)")
echo "PGBIN=$PGBIN"
"$PGBIN/postgres" --version 2>&1 || postgres --version 2>&1

echo "=== io_uring support in Alpine PG18? (pg_config / strings) ==="
strings "$PGBIN/postgres" 2>/dev/null | grep -iE 'io_uring|liburing' | head -3
ldd "$PGBIN/postgres" 2>/dev/null | grep -i uring || echo "NO_DYNAMIC_URING_LINK"
apk info -e liburing 2>/dev/null && echo "liburing_installed" || echo "liburing_absent"

echo "=== load zfs arc_max=32 GiB ==="
echo "options zfs zfs_arc_max=34359738368" > /etc/modprobe.d/zfs.conf
modprobe zfs zfs_arc_max=34359738368 2>&1
echo "MODPROBE_RC=$?"
cat /sys/module/zfs/parameters/zfs_arc_max 2>&1

echo "=== create MATCHED pool on the raw NVMe /dev/vdc ==="
POOLDEV=/dev/vdc
[ -b "$POOLDEV" ] || { for d in /dev/vdb /dev/vdc /dev/vdd; do [ -b "$d" ] && SZ=$(blockdev --getsize64 "$d") && [ "$SZ" -gt 500000000000 ] && POOLDEV=$d && break; done; }
echo "POOLDEV=$POOLDEV size=$(blockdev --getsize64 $POOLDEV)"
zpool destroy -f pgdata 2>/dev/null
wipefs -a "$POOLDEV" 2>/dev/null
zpool labelclear -f "$POOLDEV" 2>/dev/null
zpool create -f -o ashift=12 -O recordsize=8k -O compression=off -O atime=off \
  -O sync=standard -O logbias=latency -O primarycache=all -O mountpoint=/data pgdata "$POOLDEV" 2>&1
echo "ZPOOL_CREATE_RC=$?"
zpool get ashift pgdata 2>&1
zfs get recordsize,compression,atime,sync,logbias,primarycache,mountpoint pgdata 2>&1
zfs --version 2>&1 | head -1

echo "=== initdb (musl PG), locale C, trust hba ==="
INITDB="$PGBIN/initdb"
[ -x "$INITDB" ] || INITDB=$(command -v initdb)
mkdir -p /data/pg
adduser -D -H postgres 2>/dev/null || true
chown -R postgres /data
su postgres -s /bin/sh -c "$INITDB -D /data/pg -U postgres --locale=C --encoding=UTF8 -A trust" 2>&1 | tail -6
echo "INITDB_RC=$?"
cat >> /data/pg/pg_hba.conf <<EOF
host all all 0.0.0.0/0 trust
EOF
echo "listen_addresses='*'" >> /data/pg/postgresql.conf
echo "PGBIN=$PGBIN" > /tmp/pgbin.env
echo "=== END $(date) ==="
echo LINUX_SETUP_DONE
