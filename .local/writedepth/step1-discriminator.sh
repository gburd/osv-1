#!/bin/bash
# STEP 1 discriminator: syncwrite threads=8/16/32, ALL env OFF (baseline).
# Collects RESULT ZILSVC (device SERVICE time + vdev-queue write depth),
# ZILDEPTH (lwb pipeline depth), ZILISSUER (zl_parallel branch counts),
# ZILFLUSHLAT (write vs flush split), and syncwrite op/s.
# Boots zfs_builder.elf natively (qemu 7.2 -M pc) with the raw instance-store
# NVMe as vblk1 (num-queues>1). Runs on the metal. Results -> /work/writedepth-out/
set -u
OSV=/work/osv
ELF=$OSV/build/release.x64/zfs_builder.elf
DATADISK=$(cat /work/DATADISK 2>/dev/null || echo /dev/nvme0n1)
OUT=/work/writedepth-out
mkdir -p "$OUT/logs"
NQ="${NQ:-8}"
MEM="${MEM:-32G}"
CPUS="${CPUS:-32}"
SECS="${SECS:-30}"
REPS="${REPS:-3}"
TIMEOUT="${TIMEOUT:-360}"

THROW=$(mktemp /tmp/vblk0.XXXX.img); qemu-img create -f raw "$THROW" 64M >/dev/null 2>&1

run_one() {   # $1=threads
  local T="$1"
  local tag="t${T}"
  local log="$OUT/logs/${tag}.log"
  sudo dd if=/dev/zero of="$DATADISK" bs=1M count=16 conv=fsync 2>/dev/null
  local KV="vdevs=/dev/vblk1 threads=${T} secs=${SECS} reps=${REPS} recsize=8k comp=off impl=openzfs"
  # ALL levers OFF (baseline discriminator). MQ_COMPLETE=1 is #1509 default-on.
  local APPEND="--norandom --nomount --noinit --env=OSV_BLK_MQ_COMPLETE=1 --preload-zfs-library /zfs-bench.so syncwrite ${KV}"
  echo "== $tag : threads=$T nq=$NQ (baseline, all levers off) ==" | tee "$log"
  pkill -9 -f qemu-system 2>/dev/null; sleep 1
  timeout "$TIMEOUT" sudo qemu-system-x86_64 \
    -kernel "$ELF" -m "$MEM" -smp "$CPUS" \
    -cpu host -enable-kvm -nographic -no-reboot \
    -device virtio-blk-pci,id=blk0,drive=hd0 \
    -drive file=$THROW,if=none,id=hd0,format=raw,cache=writeback,aio=threads \
    -device virtio-blk-pci,id=blk1,drive=hd1,num-queues=$NQ \
    -drive file=$DATADISK,if=none,id=hd1,format=raw,cache=none,aio=native \
    -append "$APPEND" 2>&1 | tee -a "$log"
  echo "== qemu exit ${PIPESTATUS[0]} ==" | tee -a "$log"
}

echo "### STEP 1 discriminator  datadisk=$DATADISK nq=$NQ mem=$MEM cpus=$CPUS secs=$SECS reps=$REPS"
for T in 8 16 32; do run_one "$T"; done
rm -f "$THROW"

echo; echo "############ DISCRIMINATOR SUMMARY ############"
for T in 8 16 32; do
  L="$OUT/logs/t${T}.log"
  echo "--- threads=$T ---"
  grep -E "RESULT ZILSVC|RESULT ZILDEPTH|RESULT ZILISSUER|RESULT ZILFLUSHLAT|RESULT syncwrite" "$L" 2>/dev/null | sort -u
done
echo "STEP1_DONE"
