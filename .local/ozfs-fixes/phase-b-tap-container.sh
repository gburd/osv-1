#!/bin/bash
# Phase B in the host-network container (osv-net): tap0 + virtio-net, guest PG
# reachable cross-instance via host ENI DNAT (172.31.12.162:5432 -> guest).
set -u
IMG=/b/build/last/usr.img
KERNEL=/b/build/last/loader.elf
DATADISK=/nvme/pgdata.raw
PGBIN=/b/.local/pg18/install/bin
GUEST_IP=192.168.100.2
GW=192.168.100.1
INIT="/zpool.so import -f -N pgdata ; /zfs.so mount pgdata ; $PGBIN/postgres -D /data"
APPEND="--rootfs=zfs --ip=eth0,$GUEST_IP,255.255.255.0 --defaultgw=$GW $INIT"

echo "== Phase B (osv-net, tap0): guest PG at $GUEST_IP:5432 =="
exec qemu-system-x86_64 -enable-kvm -cpu host -m 32G -smp 8 -nographic -no-reboot \
  -kernel "$KERNEL" -append "$APPEND" \
  -device virtio-blk-pci,id=blk0,drive=hd0 \
  -drive "file=$IMG,if=none,id=hd0,cache=writeback,aio=threads" \
  -device virtio-blk-pci,id=blk1,drive=hd1 \
  -drive "file=$DATADISK,if=none,id=hd1,format=raw,cache=writeback,aio=threads" \
  -netdev tap,id=un0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-pci,netdev=un0,mac=52:54:00:12:34:56 \
  -s
