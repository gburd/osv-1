#!/bin/bash
# Runs ONE syncwrite point inside the bld container. Launched detached
# (docker exec -d bld bash /run-point.sh ...) so the ssh pipe never holds
# qemu. Writes full output to $LOG. Poll $LOG for "RESULT" + "ZFSBENCH_DONE".
# Args: LOG THREADS SECS REPS [EXTRA_ENV_APPEND] [EXTRA_WL_KV]
set -u
LOG="$1"; T="$2"; SECS="$3"; REPS="$4"; EXTRA="${5:-}"; WLEXTRA="${6:-}"
cd /work/osv
pkill -9 -f qemu-system-x86 2>/dev/null; sleep 1
THROW=$(mktemp /tmp/vblk0.XXXX.img); qemu-img create -f raw "$THROW" 64M >/dev/null 2>&1
timeout 300 qemu-system-x86_64 -M pc -cpu host -enable-kvm -nographic -no-reboot \
  -m 64G -smp 32 -kernel build/release.x64/zfs_builder.elf \
  -device virtio-blk-pci,id=blk0,drive=hd0 \
  -drive file="$THROW",if=none,id=hd0,format=raw,cache=writeback,aio=threads \
  -device virtio-blk-pci,id=blk1,drive=hd1 \
  -drive file=/dev/nvme1n1,if=none,id=hd1,format=raw,cache=none,aio=native \
  -append "--norandom --nomount --noinit $EXTRA --preload-zfs-library /zfs-bench.so syncwrite threads=$T secs=$SECS reps=$REPS recsize=8k bs=8192 vdevs=/dev/vblk1 $WLEXTRA" \
  > "$LOG" 2>&1
echo "ZFSBENCH_DONE rc=$?" >> "$LOG"
rm -f "$THROW"
