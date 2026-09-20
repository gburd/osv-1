#!/bin/bash
# Boot the Linux (Alpine edge, musl) KVM guest for the Linux arm.
# SAME qemu / -M pc / virtio-blk / raw-pool-file-on-NVMe as the OSv guest.
# Modes:
#   boot   -- boot Alpine guest with the cloud-init seed (root ssh key, static IP 192.168.100.2)
# ARGS: <mode>
set -x
MODE="${1:-boot}"
POOLIMG=/mnt/nv/pgdata.raw
ALPINE=/mnt/nv/alpine.qcow2
SEED=/mnt/nv/seed.iso
LOG=/work/console-linux-$(date +%H%M%S).log

# Fresh raw pool file for the Linux arm (OSv pool already destroyed by caller).
# recreate at 600G to match the OSv arm exactly.
if [ ! -f "$POOLIMG" ]; then truncate -s 600G "$POOLIMG"; fi
ls -l "$POOLIMG" "$ALPINE" "$SEED"

# grow the alpine root disk so apk + PG fit (200MB base is too small)
qemu-img resize "$ALPINE" 20G 2>&1 | tail -2

# 32 vCPU / 64 GiB, SAME as OSv guest. -M pc -cpu host -enable-kvm, qemu 8.1.3 (fedora:39 container).
# virtio-blk for BOTH the root disk and the NVMe-backed pool file (vdb).
docker exec -d bld bash -lc "cd /work && exec qemu-system-x86_64 -M pc -cpu host -enable-kvm \
  -smp 32 -m 64G -nographic -vga none -boot order=c \
  -drive file=$ALPINE,if=none,id=root0,cache=none,aio=native,format=qcow2 \
  -device virtio-blk-pci,drive=root0,bootindex=0 \
  -drive file=$SEED,if=ide,media=cdrom,format=raw \
  -drive file=$POOLIMG,if=none,id=hd1,cache=none,aio=native,format=raw \
  -device virtio-blk-pci,drive=hd1,scsi=off,bootindex=2 \
  -netdev tap,id=hn0,ifname=tap0,script=no,downscript=no,vhost=off \
  -device virtio-net-pci,netdev=hn0 \
  -device virtio-rng-pci \
  >> $LOG 2>&1"
sleep 3
echo "LOG=$LOG"
