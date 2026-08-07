#!/bin/bash
# serve-only.sh -- boot OSv+PG serving over tap0 (real NIC), rxprof+wakeprof armed,
# leave it running. Assumes the pool is already seeded (/mnt/nvme/pgdata-osv.raw).
set -u
KERNEL=/mnt/nvme/osv-img/loader.elf
IMG=/mnt/nvme/osv-img/usr.img
BLK=/mnt/nvme/pgdata-osv.raw
SMP="${SMP:-32}"; MEM="${MEM:-16G}"
QEMU=qemu-system-x86_64
GUEST_IP=192.168.100.2; GW=192.168.100.1
WAKE_STEAL="${WAKE_STEAL:-0}"
SB="${SB:-1GB}"
PGARGS="-c listen_addresses=* -c port=5432 -c unix_socket_directories="
PGARGS="$PGARGS -c shared_buffers=$SB -c effective_cache_size=4GB -c work_mem=16MB"
PGARGS="$PGARGS -c max_connections=256 -c huge_pages=off"
PGARGS="$PGARGS -c shared_preload_libraries=plpgsql"
PGARGS="$PGARGS -c io_method=sync"
PGARGS="$PGARGS -c dynamic_shared_memory_type=posix"
PGARGS="$PGARGS -c autovacuum=off -c max_parallel_workers_per_gather=0"
INIT="/zpool.so import -f -N pgdata ; /zfs.so set sync=standard pgdata ; /zfs.so mount pgdata ; /b/.local/pg18/install/bin/postgres -D /data $PGARGS"
APPEND="--env=OSV_RXPROF=1 --env=OSV_WAKEPROF=1 --env=OSV_WAKE_STEAL=$WAKE_STEAL --rootfs=zfs --ip=eth0,$GUEST_IP,255.255.255.0 --defaultgw=$GW $INIT"
rm -f /tmp/osv.log
nohup $QEMU -machine pc -accel kvm -cpu host -m "$MEM" -smp "$SMP" \
  -nographic -no-reboot -kernel "$KERNEL" -append "$APPEND" \
  -device virtio-blk-pci,id=blk0,drive=hd0 -drive "file=$IMG,if=none,id=hd0,cache=writeback,aio=threads" \
  -device virtio-blk-pci,id=blk1,drive=hd1 -drive "file=$BLK,if=none,id=hd1,format=raw,cache=none,aio=native" \
  -netdev "tap,id=n0,ifname=tap0,script=no,downscript=no,vhost=on,queues=8" \
  -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56,mq=on,vectors=17 \
  > /tmp/osv.log 2>&1 &
echo $! > /tmp/osv.qpid
for i in $(seq 1 180); do
  sleep 1
  grep -q "ready to accept" /tmp/osv.log 2>/dev/null && { echo "OSV_READY ${i}s WAKE_STEAL=$WAKE_STEAL"; exit 0; }
  grep -qiE "Aborted|panic|Assertion failed" /tmp/osv.log && { echo "OSV_CRASH:"; grep -avE "iPXE|SeaBIOS" /tmp/osv.log | tail -20; exit 1; }
done
echo OSV_NOTREADY; grep -avE "iPXE|SeaBIOS" /tmp/osv.log | tail -20; exit 1
