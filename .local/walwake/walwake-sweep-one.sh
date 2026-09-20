#!/bin/bash
# ONE syncwrite data point, run inside bld container. qemu serial MUST go
# through a PIPE (tee), a plain > file loses OSv -nographic output. Prints
# to stdout (streamed over the foreground ssh) AND tees to $OUT in the guest.
# Args passed by the local driver. cache=writeback,aio=threads on blk0 REQUIRED.
set -uo pipefail
OUT="$1"; shift
WLKV="$*"
SMP="${SMP:-32}"; MEM="${MEM:-64G}"; TIMEOUT="${TIMEOUT:-140}"
ENV_APPEND="${ENV_APPEND:-}"
ELF=/work/osv/build/release.x64/zfs_builder.elf

sudo docker exec bld bash -lc "
cd /work/osv
pkill -9 -f qemu-system-x86 2>/dev/null; sleep 1
THROW=\$(mktemp /tmp/vblk0.XXXX.img); qemu-img create -f raw \$THROW 64M >/dev/null 2>&1
( timeout $TIMEOUT qemu-system-x86_64 -M pc -cpu host -enable-kvm -nographic -no-reboot \
  -m $MEM -smp $SMP -kernel $ELF \
  -device virtio-blk-pci,id=blk0,drive=hd0 \
  -drive file=\$THROW,if=none,id=hd0,format=raw,cache=writeback,aio=threads \
  -device virtio-blk-pci,id=blk1,drive=hd1 \
  -drive file=/dev/nvme1n1,if=none,id=hd1,format=raw,cache=none,aio=native \
  -append '--norandom --nomount --noinit $ENV_APPEND --preload-zfs-library /zfs-bench.so $WLKV'; \
  echo QEMU_RC=\$? ) 2>&1 | tee $OUT
rm -f \$THROW
"
