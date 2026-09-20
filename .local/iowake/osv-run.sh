#!/bin/bash
# OSv arm: boot zfs_builder.elf under QEMU/KVM in the fedora:39 container,
# NVMe /dev/nvme1n1 as virtio-blk (vblk1), run zfs-bench.so syncwrite workloads.
# -M pc (fedora qemu 8.1.3 can boot OSv; AL2023 qemu 11 q35 hangs at AHCI).
# vblk0 = throwaway 64M; real NVMe = vblk1; harness default vdevs=/dev/vblk1.
# Runs INSIDE container via docker exec. Args: <workload+kv...>
set -x
OUT="$1"; shift
WLKV="$*"
ELF=/work/osv/build/release.x64/zfs_builder.elf
TIMEOUT="${TIMEOUT:-240}"

sudo docker exec bld bash -lc "
set -x
cd /work/osv
pkill -9 -f qemu-system-x86 2>/dev/null; sleep 1
THROW=\$(mktemp /tmp/vblk0.XXXX.img); qemu-img create -f raw \$THROW 64M >/dev/null 2>&1
timeout $TIMEOUT qemu-system-x86_64 -M pc -cpu host -enable-kvm -nographic -no-reboot \
  -m 8G -smp 8 \
  -kernel $ELF \
  -device virtio-blk-pci,id=blk0,drive=hd0 \
  -drive file=\$THROW,if=none,id=hd0,format=raw,cache=writeback,aio=threads \
  -device virtio-blk-pci,id=blk1,drive=hd1 \
  -drive file=/dev/nvme1n1,if=none,id=hd1,format=raw,cache=none,aio=native \
  -append '--norandom --nomount --noinit --preload-zfs-library /zfs-bench.so $WLKV'
  rc=\$?
  rm -f \$THROW
  echo \"== qemu exit rc=\$rc ==\"
" 2>&1 | tee "$OUT"
