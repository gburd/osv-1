#!/bin/bash
# Run ONE syncwrite point via NATIVE qemu 7.2 on Debian (NO docker).
# Args: LOG MACHINE THREADS SECS REPS [EXTRA_BOOT_ENV]
# EXTRA_BOOT_ENV e.g. OSV_ZIL_WAKE_UNLOCKED=1 OSV_BLK_MQ_COMPLETE=1
set -u
LOG="$1"; MACH="$2"; T="$3"; SECS="$4"; REPS="$5"; EXTRA="${6:-}"
cd /home/admin/osv
sudo pkill -9 -f qemu-system-x86 2>/dev/null; sleep 1
THROW=$(mktemp /tmp/vblk0.XXXX.img); qemu-img create -f raw "$THROW" 64M >/dev/null 2>&1
# NVMe pool device: /dev/nvme1n1 (instance store, unformatted). virtio-blk num-queues=32
# so per-queue completion (OSV_BLK_MQ_COMPLETE) can parallelize the completion drain.
sudo timeout 360 qemu-system-x86_64 -M "$MACH" -cpu host -enable-kvm -nographic -no-reboot \
  -m 64G -smp 32 -kernel build/release.x64/zfs_builder.elf \
  -device virtio-blk-pci,id=blk0,drive=hd0 \
  -drive file="$THROW",if=none,id=hd0,format=raw,cache=writeback,aio=threads \
  -device virtio-blk-pci,id=blk1,drive=hd1,num-queues=32 \
  -drive file=/dev/nvme1n1,if=none,id=hd1,format=raw,cache=none,aio=native \
  -append "--norandom --nomount --noinit $EXTRA --preload-zfs-library /zfs-bench.so syncwrite threads=$T secs=$SECS reps=$REPS recsize=8k bs=8192 vdevs=/dev/vblk1" \
  > "$LOG" 2>&1
echo "ZFSBENCH_DONE rc=$?" >> "$LOG"
sudo rm -f "$THROW"
