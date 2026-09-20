#!/bin/bash
# STEP B isolate A/B: syncwrite threads=8/16/32, OSV_ZIL_FLUSH_INLINE off vs on.
# Boots zfs_builder.elf natively (qemu 7.2 -M pc) with the raw instance-store
# NVMe as vblk1 (num-queues>1). Captures RESULT ZILFLUSHLAT / ZILDEPTH / op-rate.
# Runs on the metal. Results -> /work/flushinline-out/
set -u
OSV=/work/osv
ELF=$OSV/build/release.x64/zfs_builder.elf
BENCH=$OSV/build/release.x64/zfs-bench.so   # already in bootfs; path informational
DATADISK=$(cat /work/DATADISK 2>/dev/null || echo /dev/nvme0n1)
OUT=/work/flushinline-out
mkdir -p "$OUT/logs"
NQ="${NQ:-8}"          # virtio-blk num-queues (>1 for #1509 per-queue completion)
MEM="${MEM:-32G}"
CPUS="${CPUS:-32}"
SECS="${SECS:-30}"
REPS="${REPS:-3}"
TIMEOUT="${TIMEOUT:-360}"

# vblk0 throwaway; real data disk = vblk1 (whole raw NVMe). Zero the ZFS label
# region between runs so each pool-create starts clean.
THROW=$(mktemp /tmp/vblk0.XXXX.img); qemu-img create -f raw "$THROW" 64M >/dev/null 2>&1

run_one() {   # $1=threads $2=inline(0/1)
  local T="$1" INL="$2"
  local tag="t${T}_inline${INL}"
  local log="$OUT/logs/${tag}.log"
  # wipe leading + trailing labels so ZFS won't see a stale pool
  sudo dd if=/dev/zero of="$DATADISK" bs=1M count=16 conv=fsync 2>/dev/null
  local WL="syncwrite"
  local KV="vdevs=/dev/vblk1 threads=${T} secs=${SECS} reps=${REPS} recsize=8k comp=off impl=openzfs"
  local APPEND="--norandom --nomount --noinit --env=OSV_ZIL_FLUSH_INLINE=${INL} --env=OSV_BLK_MQ_COMPLETE=1 --preload-zfs-library /zfs-bench.so ${WL} ${KV}"
  echo "== $tag : threads=$T inline=$INL nq=$NQ ==" | tee "$log"
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

echo "### STEP B isolate A/B  datadisk=$DATADISK nq=$NQ mem=$MEM cpus=$CPUS secs=$SECS reps=$REPS"
for T in 8 16 32; do
  for INL in 0 1; do
    run_one "$T" "$INL"
  done
done
rm -f "$THROW"

echo; echo "############ SUMMARY ############"
for T in 8 16 32; do
  for INL in 0 1; do
    L="$OUT/logs/t${T}_inline${INL}.log"
    echo "--- threads=$T inline=$INL ---"
    grep -E "OSV_ZIL_FLUSH_INLINE:|RESULT ZILFLUSHLAT|RESULT ZILDEPTH|RESULT syncwrite" "$L" 2>/dev/null | sort -u
  done
done
echo "STEP_B_DONE"
