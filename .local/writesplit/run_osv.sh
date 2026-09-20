#!/bin/bash
# OSv arm: boot zfs_builder.elf under qemu -M pc + KVM, run zfs-bench syncwrite
# threads=N on raw nvme1n1 (vblk0). Matches prior lwbpipe STEP1a/STEP2d:
#   32 vCPU / 64 GiB guest, single-vdev raw NVMe, MQ_COMPLETE=1 (default-on after #1509
#   or via env), sync=standard recordsize=8k ashift=12 logbias=latency.
# Emits RESULT ZILDEPTH / ZILFLUSHLAT / syncwrite op/s lines.
set -u
ELF=$HOME/osvbuild/build/release.x64/zfs_builder.elf
DISK=/dev/nvme1n1
OUT=$HOME/writesplit_osv
mkdir -p $OUT
CPUS=${CPUS:-32}
MEM=${MEM:-64G}
SECS=${SECS:-30}
MQ=${MQ:-1}   # OSV_BLK_MQ_COMPLETE

for THR in "$@"; do
  echo "======== OSv t=$THR (MQ=$MQ) ========"
  sudo pkill -9 -f qemu-system-x86 2>/dev/null || true; sleep 2
  sudo wipefs -a $DISK >/dev/null 2>&1 || true
  LOG=$OUT/osv_t${THR}.log
  # vblk0 = raw NVMe (num-queues=4 to match prior run), cache=none aio=native.
  sudo timeout 200 qemu-system-x86_64 -M pc -cpu host -enable-kvm \
    -m $MEM -smp $CPUS -nographic -no-reboot \
    -kernel $ELF \
    -device virtio-blk-pci,id=blk0,drive=hd0,num-queues=4 \
    -drive file=$DISK,if=none,id=hd0,format=raw,cache=none,aio=native \
    -append "--nomount --noinit --env=OSV_BLK_MQ_COMPLETE=$MQ --preload-zfs-library /zfs-bench.so syncwrite impl=openzfs vdevs=/dev/vblk0 recsize=8k bs=8192 threads=$THR secs=$SECS reps=1" \
    > $LOG 2>&1
  echo "rc=$?"
  sudo pkill -9 -f qemu-system-x86 2>/dev/null || true; sleep 1
  echo "---- RESULT lines t=$THR ----"
  grep -E "^RESULT|MQ_COMPLETE|mode=" $LOG || echo "(no RESULT lines - see $LOG)"
done
echo "DONE"
