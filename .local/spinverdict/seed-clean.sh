#!/bin/bash
# Clean ONE-TIME seed, foreground+bounded, full serial capture, NO shell tokens
# (OSv runner has no shell; only /path.so and /usr/bin programs, ';'-separated).
set -x
B=/work/osv/build/last
DATADISK=$(cat /work/DATADISK 2>/dev/null || echo /dev/nvme0n1)
LOG=/work/seed-clean-$(date +%H%M%S).log
NQ=${POOL_NUM_QUEUES:-8}
EXTRA="$*"

CMD="/zpool.so create -f -o ashift=12 -O recordsize=8k -O compression=off -O atime=off -O sync=standard -O logbias=latency -O primarycache=all -O mountpoint=/data pgdata /dev/vblk1 ; /usr/bin/seed_copy /data-seed /data/pg ; /zfs.so get used pgdata ; /zpool.so export pgdata"
BOOTARGS="--rootfs=rofs --ip=eth0,192.168.100.2,255.255.255.0 --defaultgw=192.168.100.1 --nameserver=192.168.100.1 $EXTRA"

sudo pkill -9 -f qemu-system-x86 2>/dev/null; sleep 2
sudo ip link set tap0 up 2>/dev/null

sudo timeout 300 qemu-system-x86_64 -M pc -cpu host -enable-kvm -nographic -vga none \
  -smp 32 -m 32G \
  -kernel "$B/loader.elf" -append "$BOOTARGS $CMD" \
  -drive file=$B/usr.img,if=none,id=hd0,cache=none,aio=native,format=qcow2 \
  -device virtio-blk-pci,drive=hd0,scsi=off \
  -drive file=$DATADISK,if=none,id=hd1,cache=none,aio=native,format=raw \
  -device virtio-blk-pci,drive=hd1,scsi=off,num-queues=$NQ \
  -netdev tap,id=hn0,ifname=tap0,script=no,downscript=no,vhost=off \
  -device virtio-net-pci,netdev=hn0 -device virtio-rng-pci \
  > "$LOG" 2>&1
echo "QEMU_EXIT_RC=$?  LOG=$LOG"
tail -20 "$LOG"
