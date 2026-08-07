#!/bin/bash
# Robust seed: boot seed qemu in background, wait for cpiod readiness, push in
# foreground (visible), then wait for export. $1 = image tag.
set -u
TAG="${1:-unfixed}"
SMP="${SMP:-8}"; MEM="${MEM:-16G}"
KERNEL=/mnt/nvme/img-$TAG/loader.elf
IMG=/mnt/nvme/img-$TAG/usr.img
BLK=/mnt/nvme/pgdata-$TAG.raw
SEED=/mnt/nvme/pgseed
PORT=10000
LOG=/mnt/nvme/log-seed-$TAG.log
rm -f "$BLK" "$LOG"; truncate -s 60G "$BLK"
CREATE="/zpool.so create -f -o ashift=12 -O compression=lz4 -O atime=off -O recordsize=8k -m /data pgdata /dev/vblk1"
INIT="$CREATE ; /tools/cpiod.so --prefix /data/ --port $PORT ; /zpool.so export pgdata"
APPEND="--rootfs=zfs $INIT"
echo "== SEED tag=$TAG SMP=$SMP =="
setsid qemu-system-x86_64 -machine pc -accel kvm -cpu host -m "$MEM" -smp "$SMP" \
  -nographic -no-reboot \
  -kernel "$KERNEL" -append "$APPEND" \
  -device virtio-blk-pci,id=blk0,drive=hd0 -drive "file=$IMG,if=none,id=hd0,cache=writeback,aio=threads" \
  -device virtio-blk-pci,id=blk1,drive=hd1 -drive "file=$BLK,if=none,id=hd1,format=raw,cache=none,aio=native" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:$PORT" -device virtio-net-pci,netdev=n0 \
  > "$LOG" 2>&1 &
QPID=$!
# wait for cpiod to be listening
for i in $(seq 1 60); do
  grep -q "Waiting for connection" "$LOG" 2>/dev/null && break
  sleep 1
done
sleep 2
echo "== pushing seed cluster =="
python3 /mnt/nvme/harness/cpio_push.py "$SEED" 127.0.0.1 $PORT 2>&1
# wait for export/done
for i in $(seq 1 60); do
  grep -qiE "cpiod finished" "$LOG" 2>/dev/null && break
  sleep 1
done
sleep 3
kill -9 $QPID 2>/dev/null
pkill -9 -f qemu-system 2>/dev/null
grep -qiE "cpiod finished" "$LOG" && echo "SEED_OK tag=$TAG" || { echo "SEED_FAIL tag=$TAG"; tail -15 "$LOG"; }
