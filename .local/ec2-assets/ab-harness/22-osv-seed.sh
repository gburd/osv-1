#!/bin/bash
# 22-osv-seed.sh -- boot OSv, create the ZFS pgdata pool, cpiod-receive the
# host-initdb'd cluster into /data, export. Sidesteps OSv's popen()-stubbed
# initdb by initdb'ing on the host and streaming the tree in. Runs in osvq.
set -u
SMP="${SMP:-8}"; MEM="${MEM:-16G}"
OSV=/mnt/nvme/osv-img; IMG=$OSV/usr.img; KERNEL=$OSV/loader.elf
BLK=/mnt/nvme/pgdata-osv.raw
INITDIR=/mnt/nvme/pgdata-init
PORT=10000

rm -f "$BLK"; truncate -s 80G "$BLK"

CREATE="/zpool.so create -f -o ashift=12 -O compression=lz4 -O atime=off -O recordsize=8k -m /data pgdata /dev/vblk1"
INIT="$CREATE ; /tools/cpiod.so --prefix /data/ --port $PORT ; /zpool.so export pgdata"
APPEND="--rootfs=ramfs $INIT"

# pusher: wait for guest to boot+create pool+bind cpiod, then stream, retry on reset
( sleep 25
  for t in 1 2 3 4 5; do
    python3 /mnt/nvme/harness/cpio_push.py "$INITDIR" 127.0.0.1 $PORT 2>&1 | sed "s/^/[push$t] /"
    [ "${PIPESTATUS[0]}" = 0 ] && break
    echo "[push] retry in 5s"; sleep 5
  done ) &
PUSH=$!

rm -f /tmp/osv-seed.log
echo "== OSv seed: create pool + cpiod-receive cluster (SMP=$SMP MEM=$MEM) =="
timeout 300 qemu-system-x86_64 -machine pc -accel tcg,thread=multi -cpu max -m "$MEM" -smp "$SMP" \
  -nographic -no-reboot \
  -kernel "$KERNEL" -append "$APPEND" \
  -device virtio-blk-pci,id=blk0,drive=hd0 -drive "file=$IMG,if=none,id=hd0,cache=writeback,aio=threads" \
  -device virtio-blk-pci,id=blk1,drive=hd1 -drive "file=$BLK,if=none,id=hd1,format=raw,cache=none,aio=native" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:$PORT" -device virtio-net-pci,netdev=n0 \
  2>&1 | tee /tmp/osv-seed.log | grep -viE "iPXE|SeaBIOS"
wait $PUSH 2>/dev/null
echo "== seed done =="
grep -qiE "export|pushed" /tmp/osv-seed.log && echo OSV_SEED_OK || echo OSV_SEED_CHECK
