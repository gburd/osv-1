#!/bin/bash
# GENUINELY-IDLE regression check: boot the guest with a MOSTLY-IDLE workload
# (1 writer thread, but the guest's other 31 vCPUs are idle => their do_idle
# loops decide spin-vs-halt). Sample host qemu %CPU (sum over threads) during
# the run: fixed-10000 spins the full window on every idle entry on all 31 idle
# vCPUs (burns host CPU); adaptive shrinks to the floor + halts (low host CPU).
#
# The GATE: adaptive must NOT burn materially more host CPU at idle than fixed.
# Args: <tag>  env: ARM=adaptive|fixed  SECS (default 30)
set -x
TAG="$1"; SECS="${2:-40}"
ARM="${ARM:-adaptive}"
ELF=/work/osv/build/release.x64/zfs_builder.elf
SMP=32; MEM=64G
TIMEOUT=$((SECS + 120))
OUT=/scratch/idle-$TAG.txt

if [ "$ARM" = fixed ]; then
  ENV_APPEND="--env=OSV_IDLE_SPIN_ADAPTIVE=0"
else
  ENV_APPEND=""
fi
ENV_APPEND="$ENV_APPEND --env=OSV_WAKE_PULL=1 --env=OSV_ZFS_ARC_MAX=34359738368 --env=OSV_BLK_MQ_COMPLETE=1"

echo "=== IDLE-REGRESSION $TAG ARM=$ARM secs=$SECS $(date) ===" | tee "$OUT"

# Sample the qemu process %CPU during the run (host-side truth). pidstat if
# available, else top -b. Start after the bench ramps (10s) so we sample the
# steady low-activity phase, not pool import/create.
( sleep 12
  for i in $(seq 1 $((SECS/2))); do
    P=$(pgrep -f 'qemu-system-x86_64 -M pc' | head -1)
    [ -z "$P" ] && { echo "no-qemu"; sleep 2; continue; }
    # sum %CPU of all qemu threads
    CPU=$(top -b -n1 -H -p "$P" 2>/dev/null | awk 'NR>7{s+=$9} END{print s}')
    echo "t=$i qemu_pct_cpu=$CPU"
    sleep 2
  done > /scratch/idle-cpu-$TAG.samples 2>&1 ) &
SAMP=$!

# Mostly-idle workload: 1 writer thread on a 32-vCPU guest => 31 vCPUs idle.
sudo docker exec bld bash -lc "
set -x
cd /work/osv
pkill -9 -f qemu-system-x86 2>/dev/null; sleep 1
THROW=\$(mktemp /tmp/vblk0.XXXX.img); qemu-img create -f raw \$THROW 64M >/dev/null 2>&1
timeout $TIMEOUT qemu-system-x86_64 -M pc -cpu host -enable-kvm -nographic -no-reboot \
  -m $MEM -smp $SMP \
  -kernel $ELF \
  -device virtio-blk-pci,id=blk0,drive=hd0 \
  -drive file=\$THROW,if=none,id=hd0,format=raw,cache=writeback,aio=threads \
  -device virtio-blk-pci,id=blk1,drive=hd1 \
  -drive file=/dev/nvme1n1,if=none,id=hd1,format=raw,cache=none,aio=native \
  -append '--norandom --nomount --noinit $ENV_APPEND --preload-zfs-library /zfs-bench.so syncwrite pool=bench vdevs=/dev/vblk1 threads=1 secs=$SECS reps=1 recsize=8k'
  rc=\$?
  rm -f \$THROW
  echo \"== qemu exit rc=\$rc ==\"
" 2>&1 | tee -a "$OUT"

wait $SAMP 2>/dev/null
echo "--- idle-cpu samples ---" | tee -a "$OUT"
cat /scratch/idle-cpu-$TAG.samples | tee -a "$OUT"
# median of the samples
MED=$(awk -F= '/qemu_pct_cpu=/{print $3}' /scratch/idle-cpu-$TAG.samples | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')
echo "IDLE_QEMU_PCT_CPU_MEDIAN=$MED" | tee -a "$OUT"
echo "=== IDLE-REGRESSION $TAG DONE $(date) ===" | tee -a "$OUT"
