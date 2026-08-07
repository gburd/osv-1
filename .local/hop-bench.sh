#!/bin/bash
# hop-bench.sh -- run INSIDE a fedora qemu container (--privileged --device /dev/kvm --network host).
# Phase A: seed ZFS pgdata pool (cpiod over SLIRP) from /mnt/nvme/pgseed.
# Phase B: boot OSv+PG serving over tap0+vhost (REAL NIC, NOT loopback), rxprof+wakeprof armed.
# Then run pgbench RO from the host at c8 (peak) and c32 (collapse), bracketing each
# load window with profiler snapshots so per-window HOP deltas can be computed.
set -u
KERNEL=/mnt/nvme/osv-img/loader.elf
IMG=/mnt/nvme/osv-img/usr.img
BLK=/mnt/nvme/pgdata-osv.raw
SEED=/mnt/nvme/pgseed
SMP="${SMP:-32}"; MEM="${MEM:-16G}"
QEMU=qemu-system-x86_64
GUEST_IP=192.168.100.2; GW=192.168.100.1
PORT=10000
PGB=/usr/bin/pgbench
PSQL=/usr/bin/psql
export PGPASSWORD=

# ---- PGARGS: LEVER1 working set: DEFAULT mmap shared mem + io_method=sync (NOT sysv) ----
SB="${SB:-1GB}"
PGARGS="-c listen_addresses=* -c port=5432 -c unix_socket_directories="
PGARGS="$PGARGS -c shared_buffers=$SB -c effective_cache_size=4GB -c work_mem=16MB"
PGARGS="$PGARGS -c max_connections=256 -c huge_pages=off"
PGARGS="$PGARGS -c shared_preload_libraries=plpgsql"
PGARGS="$PGARGS -c io_method=sync"
PGARGS="$PGARGS -c dynamic_shared_memory_type=posix"
PGARGS="$PGARGS -c autovacuum=off -c max_parallel_workers_per_gather=0"

echo "===== PHASE A: mkpool + cpiod-receive cluster (SLIRP) ====="
rm -f "$BLK"; truncate -s 40G "$BLK"
CREATE="/zpool.so create -f -o ashift=12 -O compression=lz4 -O atime=off -O recordsize=8k -m /data pgdata /dev/vblk1"
INIT="$CREATE ; /tools/cpiod.so --prefix /data/ --port $PORT ; /zpool.so export pgdata"
APPEND="--rootfs=zfs $INIT"
rm -f /tmp/seed.log
( sleep 12
  for t in 1 2 3; do
    python3 /mnt/nvme/harness/cpio_push.py "$SEED" 127.0.0.1 $PORT 2>&1 | sed "s/^/[push$t] /"
    [ "${PIPESTATUS[0]}" = 0 ] && break
    echo "[push] retry 4s"; sleep 4
  done ) &
PUSH=$!
timeout 300 $QEMU -machine pc -accel kvm -cpu host -m "$MEM" -smp 8 \
  -nographic -no-reboot -kernel "$KERNEL" -append "$APPEND" \
  -device virtio-blk-pci,id=blk0,drive=hd0 -drive "file=$IMG,if=none,id=hd0,cache=writeback,aio=threads" \
  -device virtio-blk-pci,id=blk1,drive=hd1 -drive "file=$BLK,if=none,id=hd1,format=raw,cache=none,aio=native" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:$PORT" -device virtio-net-pci,netdev=n0 \
  2>&1 | tee /tmp/seed.log | grep -viE "iPXE|SeaBIOS" | tail -12
wait $PUSH 2>/dev/null
grep -qiE "cpiod finished|export" /tmp/seed.log && echo OSV_SEED_OK || { echo OSV_SEED_FAIL; tail -20 /tmp/seed.log; exit 1; }

echo "===== PHASE B: boot OSv+PG serving over tap0+vhost (real NIC), rxprof+wakeprof ====="
INIT="/zpool.so import -f -N pgdata ; /zfs.so set sync=standard pgdata ; /zfs.so mount pgdata ; /b/.local/pg18/install/bin/postgres -D /data $PGARGS"
APPEND="--rootfs=zfs --ip=eth0,$GUEST_IP,255.255.255.0 --defaultgw=$GW $INIT"
rm -f /tmp/osv.log
# env passes OSV_RXPROF / OSV_WAKEPROF to the guest via --env
ENVFLAGS="--env=OSV_RXPROF=1 --env=OSV_WAKEPROF=1"
APPEND="$ENVFLAGS $APPEND"
nohup $QEMU -machine pc -accel kvm -cpu host -m "$MEM" -smp "$SMP" \
  -nographic -no-reboot -kernel "$KERNEL" -append "$APPEND" \
  -device virtio-blk-pci,id=blk0,drive=hd0 -drive "file=$IMG,if=none,id=hd0,cache=writeback,aio=threads" \
  -device virtio-blk-pci,id=blk1,drive=hd1 -drive "file=$BLK,if=none,id=hd1,format=raw,cache=none,aio=native" \
  -netdev "tap,id=n0,ifname=tap0,script=no,downscript=no,vhost=on" \
  -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
  > /tmp/osv.log 2>&1 &
QPID=$!; echo $QPID > /tmp/osv.qpid
READY=0
for i in $(seq 1 180); do
  sleep 1
  grep -q "ready to accept" /tmp/osv.log 2>/dev/null && { echo "OSV_READY ${i}s"; READY=1; break; }
  grep -qiE "Aborted|panic|Assertion failed" /tmp/osv.log && { echo "OSV_CRASH:"; tail -25 /tmp/osv.log|grep -vE "iPXE|SeaBIOS"; break; }
done
if [ "$READY" != 1 ]; then echo OSV_NOTREADY; tail -30 /tmp/osv.log|grep -vE "iPXE|SeaBIOS"; kill $QPID 2>/dev/null; exit 1; fi

# prove not loopback + init bench DB
echo "RESULT inet_server_addr=$($PSQL "host=$GUEST_IP port=5432 user=postgres dbname=postgres" -tAc "select inet_server_addr()" 2>&1)"
$PSQL "host=$GUEST_IP port=5432 user=postgres dbname=postgres" -tAc "drop database if exists bench" >/dev/null 2>&1
$PSQL "host=$GUEST_IP port=5432 user=postgres dbname=postgres" -tAc "create database bench" >/dev/null 2>&1
$PGB -h $GUEST_IP -p 5432 -U postgres -i -s "${SCALE:-50}" -q bench 2>&1 | tail -1

run_window() {
  local C=$1 DUR=${2:-30}
  local J=$C; [ "$C" -gt 8 ] && J=8
  echo "===RXPROF-SNAPSHOT-BEFORE-c$C==="; grep -E "^RXPROF |^WAKEPROF " /tmp/osv.log | tail -12
  local OUT
  OUT=$($PGB -h $GUEST_IP -p 5432 -U postgres -S -c "$C" -j "$J" -T "$DUR" bench 2>&1)
  local TPS LAT; TPS=$(echo "$OUT"|awk '/^tps/{print $3;exit}'); LAT=$(echo "$OUT"|awk '/latency average/{print $4;exit}')
  echo "RESULT: RO c$C tps=$TPS lat_ms=$LAT"
  sleep 6   # let one more 5s dump land after the window
  echo "===RXPROF-SNAPSHOT-AFTER-c$C==="; grep -E "^RXPROF |^WAKEPROF " /tmp/osv.log | tail -12
}

# warm, then measure the matched pair
$PGB -h $GUEST_IP -p 5432 -U postgres -S -c 8 -j 8 -T 8 bench >/dev/null 2>&1
run_window 8 30
run_window 32 30

echo "===== FULL RXPROF/WAKEPROF TAIL ====="
grep -E "^RXPROF|^WAKEPROF" /tmp/osv.log | tail -40
kill $QPID 2>/dev/null
echo "HOP_BENCH_DONE"
