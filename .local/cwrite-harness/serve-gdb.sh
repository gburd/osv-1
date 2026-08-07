#!/bin/bash
# serve-gdb.sh -- boot OSv+PG serving with DEFAULT mmap, tap0 NIC, and a gdb stub
# on tcp::1234. Runs inside a fedora qemu container (host tap0 must exist; the
# container shares host net with --network host). Waits for "ready to accept".
set -u
KERNEL=/mnt/nvme/osv-img/loader.elf
IMG=/mnt/nvme/osv-img/usr.img
BLK=/mnt/nvme/pgdata-osv.raw
PGBIN=/b/.local/pg18/install/bin
TAP=tap0; GUEST_IP=192.168.100.2; GW=192.168.100.1
SMP="${SMP:-8}"; MEM="${MEM:-16G}"
# default mmap shared memory (W1 fix), matched PG config
PGARGS="-c listen_addresses=* -c port=5432 -c unix_socket_directories="
PGARGS="$PGARGS -c shared_buffers=1GB -c effective_cache_size=4GB -c work_mem=16MB"
PGARGS="$PGARGS -c maintenance_work_mem=256MB -c max_connections=256"
PGARGS="$PGARGS -c max_wal_size=8GB -c min_wal_size=2GB -c checkpoint_timeout=15min"
PGARGS="$PGARGS -c huge_pages=off -c synchronous_commit=on"
PGARGS="$PGARGS -c io_method=sync"
PGARGS="$PGARGS -c shared_preload_libraries=plpgsql"
INIT="/zpool.so import -f -N pgdata ; /zfs.so set sync=standard pgdata ; /zfs.so mount pgdata ; $PGBIN/postgres -D /data $PGARGS"
APPEND="--rootfs=zfs --ip=eth0,$GUEST_IP,255.255.255.0 --defaultgw=$GW $INIT"
rm -f /tmp/osv.log
echo "== BOOT OSv KVM+gdb: SMP=$SMP MEM=$MEM PG@$GUEST_IP:5432 (tap0 vhost) gdb tcp::1234 =="
nohup qemu-system-x86_64 -machine pc -accel kvm -cpu host -m "$MEM" -smp "$SMP" \
  -nographic -no-reboot -gdb tcp::1234 \
  -kernel "$KERNEL" -append "$APPEND" \
  -device virtio-blk-pci,id=blk0,drive=hd0 -drive "file=$IMG,if=none,id=hd0,cache=writeback,aio=threads" \
  -device virtio-blk-pci,id=blk1,drive=hd1 -drive "file=$BLK,if=none,id=hd1,format=raw,cache=none,aio=native" \
  -netdev "tap,id=n0,ifname=$TAP,script=no,downscript=no,vhost=on" \
  -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
  > /tmp/osv.log 2>&1 &
echo $! > /tmp/osv.qpid
for i in $(seq 1 180); do
  sleep 1
  grep -q "ready to accept" /tmp/osv.log 2>/dev/null && { echo "OSV_READY ${i}s"; exit 0; }
  grep -qiE "abort|panic|Assertion failed" /tmp/osv.log && { echo "OSV_CRASH:"; tail -20 /tmp/osv.log|grep -vE "iPXE|SeaBIOS"; exit 1; }
done
echo OSV_NOTREADY; tail -15 /tmp/osv.log|grep -vE "iPXE|SeaBIOS"; exit 1
