#!/bin/bash
# Phase A (seed): create the ZFS pgdata pool on NVMe vblk1, run cpiod to receive
# the host-initdb'd PG cluster into /data, then export the pool.  A background
# pusher streams /b/.local/pg18/data-init into the guest's cpiod.
set -u
IMG=/b/build/last/usr.img
KERNEL=/b/build/last/loader.elf
DATADISK=/nvme/pgdata.raw
SRC=/b/.local/pg18/data-init

# create pool at /data ; run cpiod receiving into /data/ ; export
INIT="/zpool.so create -f -o ashift=12 -O compression=lz4 -O atime=off -O recordsize=8k -m /data pgdata /dev/vblk1"
INIT="$INIT ; /tools/cpiod.so --prefix /data/ --port 10000"
INIT="$INIT ; /zpool.so export pgdata"
APPEND="--rootfs=zfs $INIT"

echo "== Phase A (seed) boot: pool + cpiod-receive cluster =="
# background pusher: connect to hostfwd :10000 and stream the cluster
( python3 /tmp/cpio_push.py "$SRC" 127.0.0.1 10000 2>&1 | sed 's/^/[push] /' ) &
PUSH=$!

timeout 300 qemu-system-x86_64 -enable-kvm -cpu host -m 8G -smp 4 -nographic -no-reboot \
  -kernel "$KERNEL" \
  -append "$APPEND" \
  -device virtio-blk-pci,id=blk0,drive=hd0 \
  -drive "file=$IMG,if=none,id=hd0,cache=writeback,aio=threads" \
  -device virtio-blk-pci,id=blk1,drive=hd1 \
  -drive "file=$DATADISK,if=none,id=hd1,format=raw,cache=writeback,aio=threads" \
  -netdev user,id=un0,hostfwd=tcp:127.0.0.1:10000-:10000 \
  -device virtio-net-pci,netdev=un0 \
  2>&1
echo "== Phase A qemu exit rc=$? =="
wait $PUSH 2>/dev/null
