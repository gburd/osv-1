#!/bin/bash
# Phase B: boot the combined image, import the ZFS pgdata pool from NVMe vblk1
# (mounts /data), then run stock PostgreSQL on /data.  PG on ZFS-on-NVMe.
# Networking: qemu user-net hostfwd :5432 (Phase-1 local validation).
set -u
IMG=/b/build/last/usr.img
KERNEL=/b/build/last/loader.elf
DATADISK=/nvme/pgdata.raw
PGBIN=/b/.local/pg18/install/bin

# import pgdata (mounts /data) ; then postgres.  '&' would background; use ';'
# so import completes before postgres starts.
INIT="/zpool.so import -f -N pgdata"
INIT="$INIT ; /zfs.so mount pgdata"
INIT="$INIT ; $PGBIN/postgres -D /data"
APPEND="--rootfs=zfs $INIT"

echo "== Phase B boot: import pgdata + run postgres =="
echo "APPEND=$APPEND"
exec qemu-system-x86_64 -enable-kvm -cpu host -m 8G -smp 4 -nographic -no-reboot \
  -kernel "$KERNEL" \
  -append "$APPEND" \
  -device virtio-blk-pci,id=blk0,drive=hd0 \
  -drive "file=$IMG,if=none,id=hd0,cache=writeback,aio=threads" \
  -device virtio-blk-pci,id=blk1,drive=hd1 \
  -drive "file=$DATADISK,if=none,id=hd1,format=raw,cache=writeback,aio=threads" \
  -netdev user,id=un0,hostfwd=tcp:0.0.0.0:5432-:5432 \
  -device virtio-net-pci,netdev=un0 \
  -s
