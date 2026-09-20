#!/bin/bash
# Runs INSIDE the fedora:39 container. Boots zfs_builder.elf, serial -> stdout.
# Args: <workload and k=v...>
set -x
cd /work/osv
pkill -9 -f qemu-system-x86 2>/dev/null
sleep 1
THROW=$(mktemp /tmp/vblk0.XXXX.img)
qemu-img create -f raw "$THROW" 64M >/dev/null 2>&1
TIMEOUT="${TIMEOUT:-240}"
timeout "$TIMEOUT" qemu-system-x86_64 -M pc -cpu host -enable-kvm -nographic -no-reboot \
  -m 8G -smp 8 \
  -kernel /work/osv/build/release.x64/zfs_builder.elf \
  -device virtio-blk-pci,id=blk0,drive=hd0 \
  -drive file="$THROW",if=none,id=hd0,format=raw,cache=writeback,aio=threads \
  -device virtio-blk-pci,id=blk1,drive=hd1 \
  -drive file=/dev/nvme1n1,if=none,id=hd1,format=raw,cache=none,aio=native \
  -append "--norandom --nomount --noinit --preload-zfs-library /zfs-bench.so $*"
rc=$?
rm -f "$THROW"
echo "== qemu exit rc=$rc =="
