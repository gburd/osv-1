#!/bin/bash
# Boot the Ubuntu (Linux) KVM guest with NATIVE qemu 7.2.22 (-M pc), MATCHED to the OSv arm.
# RAW /dev/nvme3n1 passthrough as vdc (cache=none aio=native). 32 vCPU / 64 GiB.
set -x
UBU=/work/ubuntu.qcow2
SEED=/work/useed.iso
LOG=/work/console-ubuntu.log
: > "$LOG"
exec qemu-system-x86_64 -M pc -cpu host -enable-kvm -smp 32 -m 64G -nographic -vga none \
  -drive file=$UBU,if=none,id=root0,cache=none,aio=native,format=qcow2 \
  -device virtio-blk-pci,drive=root0,bootindex=0 \
  -drive file=$SEED,if=none,id=seed0,format=raw \
  -device virtio-blk-pci,drive=seed0 \
  -drive file=/dev/nvme3n1,if=none,id=hd1,cache=none,aio=native,format=raw \
  -device virtio-blk-pci,drive=hd1,scsi=off \
  -netdev tap,id=hn0,ifname=tap0,script=no,downscript=no,vhost=off \
  -device virtio-net-pci,netdev=hn0 \
  -device virtio-rng-pci \
  >> "$LOG" 2>&1
