#!/bin/bash
# 10-boot-osv.sh -- GUEST A: OSv + PostgreSQL 18 (musl-PIE) on ZFS.
# Runs INSIDE the fedora qemu container (host-net, /dev, /mnt/nvme bind-mounted).
# Uses the REAL tap0+vhost NIC on br0 (NOT slirp). Static guest IP.
#
# Identical-except-OS qemu knobs shared with the Linux guest (11-boot-linux.sh):
#   SMP=$SMP  MEM=$MEM  machine=pc  -netdev tap,vhost=on  virtio-net-pci  virtio-blk-pci
set -u
SMP="${SMP:-8}"
MEM="${MEM:-8G}"
OSV=/mnt/nvme/osv-img
IMG=$OSV/usr.img
KERNEL=$OSV/loader.elf
PGBIN=/b/.local/pg18/install/bin   # baked into the ramfs rootfs
PGDATA_BLK=/mnt/nvme/pgdata-osv.raw   # single virtio-blk backing (ZFS pool lives here)
TAP=tap0
GUEST_IP=192.168.100.2
GW=192.168.100.1

# Matched PG config (IDENTICAL to Linux side, see 21-pg-config.env)
. /mnt/nvme/harness/21-pg-config.env
INIT="/zpool.so import -f -N pgdata ; /zfs.so set sync=$ZFS_SYNC pgdata ; /zfs.so mount pgdata ; $PGBIN/postgres -D /data $PGARGS"
APPEND="--rootfs=ramfs --ip=eth0,$GUEST_IP,255.255.255.0 --defaultgw=$GW $INIT"

rm -f /tmp/osv.log
echo "== BOOT OSv guest A: SMP=$SMP MEM=$MEM PG@$GUEST_IP:5432 (tap0+vhost) =="
nohup qemu-system-x86_64 -machine pc -accel tcg,thread=multi -cpu max -m "$MEM" -smp "$SMP" \
  -nographic -no-reboot \
  -kernel "$KERNEL" -append "$APPEND" \
  -device virtio-blk-pci,id=blk0,drive=hd0 \
  -drive "file=$IMG,if=none,id=hd0,cache=writeback,aio=threads" \
  -device virtio-blk-pci,id=blk1,drive=hd1 \
  -drive "file=$PGDATA_BLK,if=none,id=hd1,format=raw,cache=none,aio=native" \
  -netdev "tap,id=n0,ifname=$TAP,script=no,downscript=no,vhost=on" \
  -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
  > /tmp/osv.log 2>&1 &
echo $! > /tmp/osv.qpid
for i in $(seq 1 180); do
  sleep 1
  grep -q "ready to accept" /tmp/osv.log 2>/dev/null && { echo "OSV_READY ${i}s"; exit 0; }
  grep -qiE "abort|panic|Assertion failed" /tmp/osv.log && { echo "OSV_CRASH:"; tail -20 /tmp/osv.log|grep -vE "iPXE|SeaBIOS"; exit 1; }
done
echo OSV_NOTREADY; tail -15 /tmp/osv.log | grep -vE "iPXE|SeaBIOS"; exit 1
