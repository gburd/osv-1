#!/bin/bash
# seed.sh -- create a single-file ZFS pool on a local NVMe file + cpiod-receive
# the host-initdb'd cluster into /data, export. Runs inside a fedora qemu container.
set -u
KERNEL=/mnt/nvme/osv-img/loader.elf
IMG=/mnt/nvme/osv-img/usr.img
BLK=/mnt/nvme/pgdata-osv.raw
SEED=/mnt/nvme/pgseed
PORT=10000
SMP=8; MEM=16G
QEMU=qemu-system-x86_64

rm -f "$BLK"; truncate -s 60G "$BLK"
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
  2>&1 | tee /tmp/osv-seed.log | grep -viE "iPXE|SeaBIOS" | tail -20
wait $PUSH 2>/dev/null
grep -qiE "cpiod finished|export" /tmp/osv-seed.log && echo OSV_SEED_OK || { echo OSV_SEED_FAIL; tail -20 /tmp/osv-seed.log; exit 1; }
