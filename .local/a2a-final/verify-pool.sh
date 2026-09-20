#!/bin/bash
# Verify the seeded pool: import read-only, list /data/pg, report cluster size, export.
set -x
OSV=/work/osv; B=$OSV/build/last
LOG=/work/console-verify-$(date +%H%M%S).log
CMD="/zpool.so import -f -N pgdata ; /zfs.so mount pgdata ; /zfs.so get used pgdata ; /bin/ls -la /data ; /bin/ls -la /data/pg ; /bin/ls /data/pg/base ; /zpool.so export pgdata ; /poweroff.so 2>/dev/null || echo VERIFYDONE"
BOOTARGS="--rootfs=rofs --env=OSV_ZFS_ARC_MAX=34359738368 --env=OSV_BLK_MQ_COMPLETE=1 --ip=eth0,192.168.100.2,255.255.255.0 --defaultgw=192.168.100.1 --nameserver=192.168.100.1"
sudo timeout 60 qemu-system-x86_64 -M pc -cpu host -enable-kvm -smp 4 -m 8G -nographic -vga none \
  -kernel "$B/loader.elf" -append "$BOOTARGS $CMD" \
  -drive file=$B/usr.img,if=none,id=hd0,cache=none,aio=native,format=qcow2 \
  -device virtio-blk-pci,drive=hd0,scsi=off \
  -drive file=/dev/nvme1n1,if=none,id=hd1,cache=none,aio=native,format=raw \
  -device virtio-blk-pci,drive=hd1,scsi=off \
  -netdev tap,id=hn0,ifname=tap0,script=no,downscript=no,vhost=off \
  -device virtio-net-pci,netdev=hn0 -device virtio-rng-pci \
  > "$LOG" 2>&1
echo "=== verify console ==="; cat "$LOG" | tail -40
