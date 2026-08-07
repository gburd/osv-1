#!/bin/bash
# kvm-seed-serve.sh -- run INSIDE a fedora qemu container with --device /dev/kvm.
# Phase A: create ZFS pgdata pool on vblk1, cpiod-receive the host-initdb'd
#          cluster (from /mnt/nvme/pgseed) into /data, export.
# Phase B: boot OSv+PG serving, SLIRP hostfwd 5432, verify "select 1" -> 1.
# W1 workaround (proven by agent 88daa2b8): shared_memory_type=sysv.
set -u
KERNEL=/mnt/nvme/osv-img/loader.elf
IMG=/mnt/nvme/osv-img/usr.img
BLK=/mnt/nvme/pgdata-osv.raw
SEED=/mnt/nvme/pgseed
PGBIN=/b/.local/pg18/install/bin
SMP=8; MEM=16G
QEMU=qemu-system-x86_64
PORT=10000

rm -f "$BLK"; truncate -s 40G "$BLK"

echo "===== PHASE A: mkpool + cpiod-receive cluster ====="
CREATE="/zpool.so create -f -o ashift=12 -O compression=lz4 -O atime=off -O recordsize=8k -m /data pgdata /dev/vblk1"
INIT="$CREATE ; /tools/cpiod.so --prefix /data/ --port $PORT ; /zpool.so export pgdata"
APPEND="--rootfs=zfs $INIT"
rm -f /tmp/osv-seed.log
( sleep 12
  for t in 1 2 3 4 5; do
    python3 /mnt/nvme/harness/cpio_push.py "$SEED" 127.0.0.1 $PORT 2>&1 | sed "s/^/[push$t] /"
    [ "${PIPESTATUS[0]}" = 0 ] && break
    echo "[push] retry in 4s"; sleep 4
  done ) &
PUSH=$!
timeout 300 $QEMU -machine pc -accel kvm -cpu host -m "$MEM" -smp "$SMP" \
  -nographic -no-reboot \
  -kernel "$KERNEL" -append "$APPEND" \
  -device virtio-blk-pci,id=blk0,drive=hd0 -drive "file=$IMG,if=none,id=hd0,cache=writeback,aio=threads" \
  -device virtio-blk-pci,id=blk1,drive=hd1 -drive "file=$BLK,if=none,id=hd1,format=raw,cache=none,aio=native" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:$PORT" -device virtio-net-pci,netdev=n0 \
  2>&1 | tee /tmp/osv-seed.log | grep -viE "iPXE|SeaBIOS" | tail -30
wait $PUSH 2>/dev/null
grep -qiE "cpiod finished|export" /tmp/osv-seed.log && echo OSV_SEED_OK || { echo OSV_SEED_FAIL; tail -20 /tmp/osv-seed.log; exit 1; }

echo "===== PHASE B: boot OSv+PG serving (SLIRP hostfwd 5432) ====="
SB=1GB
PGARGS="-c listen_addresses=* -c port=5432 -c unix_socket_directories="
PGARGS="$PGARGS -c shared_buffers=$SB -c effective_cache_size=4GB -c work_mem=16MB"
PGARGS="$PGARGS -c max_connections=256 -c huge_pages=off"
PGARGS="$PGARGS -c shared_preload_libraries=plpgsql"
PGARGS="$PGARGS -c shared_memory_type=sysv"          # W1 workaround: mmap-anon-shared hang
PGARGS="$PGARGS -c dynamic_shared_memory_type=posix"
INIT="/zpool.so import -f -N pgdata ; /zfs.so set sync=standard pgdata ; /zfs.so mount pgdata ; $PGBIN/postgres -D /data $PGARGS"
APPEND="--rootfs=zfs $INIT"
rm -f /tmp/osv.log
nohup $QEMU -machine pc -accel kvm -cpu host -m "$MEM" -smp "$SMP" \
  -nographic -no-reboot \
  -kernel "$KERNEL" -append "$APPEND" \
  -device virtio-blk-pci,id=blk0,drive=hd0 -drive "file=$IMG,if=none,id=hd0,cache=writeback,aio=threads" \
  -device virtio-blk-pci,id=blk1,drive=hd1 -drive "file=$BLK,if=none,id=hd1,format=raw,cache=none,aio=native" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:5432-:5432" -device virtio-net-pci,netdev=n0 \
  > /tmp/osv.log 2>&1 &
QPID=$!
READY=0
for i in $(seq 1 180); do
  sleep 1
  grep -q "ready to accept" /tmp/osv.log 2>/dev/null && { echo "OSV_READY ${i}s"; READY=1; break; }
  grep -qiE "Aborted|panic|Assertion failed" /tmp/osv.log && { echo "OSV_CRASH:"; tail -25 /tmp/osv.log|grep -vE "iPXE|SeaBIOS"; break; }
done
if [ "$READY" != 1 ]; then echo OSV_NOTREADY; tail -30 /tmp/osv.log|grep -vE "iPXE|SeaBIOS"; kill $QPID 2>/dev/null; exit 1; fi

echo "===== VERIFY: psql select 1 ====="
export PGPASSWORD=
PSQL=$(command -v psql || echo /usr/bin/psql)   # fedora libpq client (wire-compatible)
for t in 1 2 3 4 5; do
  OUT=$($PSQL -h 127.0.0.1 -p 5432 -U postgres -d postgres -tAc "select 1" 2>&1)
  echo "[try$t] $OUT"
  echo "$OUT" | grep -qx 1 && { echo "SERVE_OK"; break; }
  sleep 3
done
echo "===== postmaster log tail ====="
tail -20 /tmp/osv.log | grep -vE "iPXE|SeaBIOS"
kill $QPID 2>/dev/null
