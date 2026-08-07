#!/bin/bash
# 11-boot-linux.sh -- GUEST B: Linux (Debian 12) + PostgreSQL 18.
# IDENTICAL qemu cmdline to 10-boot-osv.sh EXCEPT the OS boot source:
#   OSv boots -kernel loader.elf ; Linux boots the qcow2 root disk.
# SAME -machine pc, -accel tcg, -cpu max, -m, -smp, SAME virtio-net tap+vhost,
# SAME virtio-blk data backing (on the SAME NVMe scratch fs).
# Runs INSIDE the fedora qemu container.
set -u
SMP="${SMP:-8}"
MEM="${MEM:-8G}"
ROOT=/mnt/nvme/debian12.qcow2         # guest OS disk (glibc PG18 lives here)
SEED=/mnt/nvme/seed.iso               # cloud-init (net + PG bootstrap)
PGDATA_BLK=/mnt/nvme/pgdata-linux.raw # SAME role as OSv's pgdata-osv.raw (data fs)
TAP=tap0

echo "== BOOT Linux guest B: SMP=$SMP MEM=$MEM PG@192.168.100.2:5432 (tap0+vhost) =="
nohup qemu-system-x86_64 -machine pc -accel tcg,thread=multi -cpu max -m "$MEM" -smp "$SMP" \
  -nographic -no-reboot \
  -device virtio-blk-pci,id=blk0,drive=hd0 \
  -drive "file=$ROOT,if=none,id=hd0,format=qcow2,cache=writeback,aio=threads" \
  -device virtio-blk-pci,id=blk1,drive=hd1 \
  -drive "file=$PGDATA_BLK,if=none,id=hd1,format=raw,cache=none,aio=native" \
  -drive "file=$SEED,if=virtio,format=raw,readonly=on" \
  -netdev "tap,id=n0,ifname=$TAP,script=no,downscript=no,vhost=on" \
  -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
  > /tmp/linux.log 2>&1 &
echo $! > /tmp/linux.qpid
echo "linux qemu pid $(cat /tmp/linux.qpid); waiting for PG on 192.168.100.2:5432 ..."
