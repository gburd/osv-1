#!/bin/bash
# STEP 2 depth-lever A/B (zero new code, uses 0039 OSV_ZIL_COMMIT_TIMEOUT_PCT).
# The discriminator showed OSv issue-gap ~290us (=~ round-trip) not ~46us window
# -> lwbs issue ~one round-trip apart -> depth ~1.4. Sweep the commit window pct
# to find whether a SMALLER window (issue sooner -> more shallow lwbs, deeper
# pipeline) or LARGER (aggregate more per lwb) raises lwb-depth toward ~10.
# Success = ZILDEPTH mean rises AND/OR ZILSVC vqwrite depth rises AND op/s scales.
set -u
OSV=/work/osv
ELF=$OSV/build/release.x64/zfs_builder.elf
DATADISK=$(cat /work/DATADISK 2>/dev/null || echo /dev/nvme0n1)
OUT=/work/writedepth-step2
mkdir -p "$OUT/logs"
NQ="${NQ:-8}"; MEM="${MEM:-32G}"; CPUS="${CPUS:-32}"; SECS="${SECS:-30}"; REPS="${REPS:-3}"; TIMEOUT="${TIMEOUT:-360}"
THROW=$(mktemp /tmp/vblk0.XXXX.img); qemu-img create -f raw "$THROW" 64M >/dev/null 2>&1

run_one() {   # $1=threads $2=pct
  local T="$1" PCT="$2"
  local tag="t${T}_pct${PCT}"
  local log="$OUT/logs/${tag}.log"
  sudo dd if=/dev/zero of="$DATADISK" bs=1M count=16 conv=fsync 2>/dev/null
  local KV="vdevs=/dev/vblk1 threads=${T} secs=${SECS} reps=${REPS} recsize=8k comp=off impl=openzfs"
  local APPEND="--norandom --nomount --noinit --env=OSV_BLK_MQ_COMPLETE=1 --env=OSV_ZIL_COMMIT_TIMEOUT_PCT=${PCT} --preload-zfs-library /zfs-bench.so syncwrite ${KV}"
  echo "== $tag ==" | tee "$log"
  pkill -9 -f qemu-system 2>/dev/null; sleep 1
  timeout "$TIMEOUT" sudo qemu-system-x86_64 \
    -kernel "$ELF" -m "$MEM" -smp "$CPUS" -cpu host -enable-kvm -nographic -no-reboot \
    -device virtio-blk-pci,id=blk0,drive=hd0 \
    -drive file=$THROW,if=none,id=hd0,format=raw,cache=writeback,aio=threads \
    -device virtio-blk-pci,id=blk1,drive=hd1,num-queues=$NQ \
    -drive file=$DATADISK,if=none,id=hd1,format=raw,cache=none,aio=native \
    -append "$APPEND" 2>&1 | tee -a "$log"
  echo "== qemu exit ${PIPESTATUS[0]} ==" | tee -a "$log"
}

# pct=0 -> use compiled default (10). Sweep small (issue sooner) and large (aggregate).
PCTS="${PCTS:-0 1 2 5 30 60}"
echo "### STEP 2 pct sweep  pcts=$PCTS  thr=8/16/32"
for T in 8 16 32; do
  for P in $PCTS; do run_one "$T" "$P"; done
done
rm -f "$THROW"

echo; echo "############ STEP2 SUMMARY (depth mean + issue-gap + op/s per pct) ############"
for T in 8 16 32; do
  for P in $PCTS; do
    L="$OUT/logs/t${T}_pct${P}.log"
    echo "--- t=$T pct=$P ---"
    grep -E "OSV_ZIL_COMMIT_TIMEOUT_PCT:|RESULT ZILDEPTH|RESULT ZILSVC|RESULT ZILISSUER|RESULT syncwrite_mt_persec" "$L" 2>/dev/null | sort -u
  done
done
echo "STEP2_DONE"
