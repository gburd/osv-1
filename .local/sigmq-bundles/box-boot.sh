#!/bin/bash
# Boot OSv+PG serving. Env: TAG, SMP, NQP (0/1=single queue; >1 = MQ vhost queues),
# SB (shared_buffers). Guest 192.168.100.2:5432 over tap0+vhost. Writes /mnt/nvme/log-osv-<TAG>.log
set -u
TAG="${TAG:-unfixed}"
SMP="${SMP:-32}"; MEM="${MEM:-32G}"; SB="${SB:-1GB}"
NQP="${NQP:-1}"
KERNEL=/mnt/nvme/img-$TAG/loader.elf
IMG=/mnt/nvme/img-$TAG/usr.img
BLK=/mnt/nvme/pgdata-$TAG.raw
TAP=tap0; GUEST_IP=192.168.100.2; GW=192.168.100.1
PGBIN=/data-does-not-matter
# PG binary lives INSIDE the image at /b/.local/pg18/install/bin per manifest.
PGBINPATH=/b/.local/pg18/install/bin
PGARGS="-c listen_addresses=* -c port=5432 -c unix_socket_directories="
PGARGS="$PGARGS -c shared_buffers=$SB -c effective_cache_size=4GB -c work_mem=16MB"
PGARGS="$PGARGS -c maintenance_work_mem=256MB -c max_connections=300"
PGARGS="$PGARGS -c max_wal_size=8GB -c min_wal_size=2GB -c checkpoint_timeout=15min"
PGARGS="$PGARGS -c checkpoint_completion_target=0.9 -c synchronous_commit=on"
PGARGS="$PGARGS -c huge_pages=off -c autovacuum=on"
PGARGS="$PGARGS -c shared_preload_libraries=plpgsql"
PGARGS="$PGARGS -c dynamic_shared_memory_type=posix"
INIT="/zpool.so import -f -N pgdata ; /zfs.so set sync=standard pgdata ; /zfs.so mount pgdata ; $PGBINPATH/postgres -D /data $PGARGS"
APPEND="--rootfs=zfs --ip=eth0,$GUEST_IP,255.255.255.0 --defaultgw=$GW $INIT"
LOG=/mnt/nvme/log-osv-$TAG.log
rm -f "$LOG"
# NIC: single-queue vs multiqueue
if [ "$NQP" -gt 1 ]; then
  VECTORS=$((2*NQP + 2))
  NETDEV="tap,id=n0,ifname=$TAP,script=no,downscript=no,vhost=on,queues=$NQP"
  NETDEVICE="virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56,mq=on,vectors=$VECTORS"
else
  NETDEV="tap,id=n0,ifname=$TAP,script=no,downscript=no,vhost=on"
  NETDEVICE="virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56"
fi
echo "== BOOT tag=$TAG SMP=$SMP MEM=$MEM SB=$SB NQP=$NQP =="
setsid qemu-system-x86_64 -machine pc -accel kvm -cpu host -m "$MEM" -smp "$SMP" \
  -nographic -no-reboot \
  -kernel "$KERNEL" -append "$APPEND" \
  -device virtio-blk-pci,id=blk0,drive=hd0 -drive "file=$IMG,if=none,id=hd0,cache=writeback,aio=threads" \
  -device virtio-blk-pci,id=blk1,drive=hd1 -drive "file=$BLK,if=none,id=hd1,format=raw,cache=none,aio=native" \
  -netdev "$NETDEV" -device "$NETDEVICE" \
  > "$LOG" 2>&1 &
echo $! > /mnt/nvme/log-osv-$TAG.qpid
for i in $(seq 1 180); do
  sleep 1
  grep -q "ready to accept" "$LOG" 2>/dev/null && { echo "OSV_READY tag=$TAG ${i}s"; exit 0; }
  grep -qiE "Aborted|panic|Assertion failed|exception nested too deeply" "$LOG" && { echo "OSV_CRASH tag=$TAG:"; grep -iE "Aborted|panic|Assertion|exception nested|nqp|VIRTIO_NET_F_MQ|Rx thread|receiver" "$LOG"|tail -15; exit 1; }
done
echo "OSV_NOTREADY tag=$TAG"; tail -20 "$LOG"|grep -vE "iPXE|SeaBIOS"; exit 1
