#!/bin/bash
# syncwrite-mt isolate A/B: adaptive idle-spin vs fixed-10000, on the SAME
# guest/host, back to back. Captures op/s + p50/p99 (from zfs-bench) AND the
# host KVM halt_exits / halt_attempted_poll DELTA over the run (the mechanism:
# fewer halt_exits => fewer IPI/VM-exit round-trips => the residual fixed).
#
# Args: <tag> <threads> <secs>   ARM chosen by env ARM=adaptive|fixed
# ENV_APPEND for the guest is derived from ARM.
set -x
TAG="$1"; THREADS="${2:-32}"; SECS="${3:-30}"
ARM="${ARM:-adaptive}"
ELF=/work/osv/build/release.x64/zfs_builder.elf
SMP="${SMP:-32}"; MEM="${MEM:-64G}"
TIMEOUT=$((SECS + 120))
OUT=/scratch/isolate-$TAG.txt

# ARM lever: adaptive = default (nothing); fixed = pin window at cap (old behavior).
if [ "$ARM" = fixed ]; then
  ENV_APPEND="--env=OSV_IDLE_SPIN_ADAPTIVE=0"
else
  ENV_APPEND=""
fi
# Both arms: wake-pull on (a2a lever), ARC cap, per-queue completion.
ENV_APPEND="$ENV_APPEND --env=OSV_WAKE_PULL=1 --env=OSV_ZFS_ARC_MAX=34359738368 --env=OSV_BLK_MQ_COMPLETE=1"

# KVM halt-counter snapshot helper (aggregate over all vCPUs of the sole VM).
snap() {
  for f in halt_exits halt_attempted_poll halt_poll_success_ns halt_poll_fail_ns halt_wakeup; do
    v=$(sudo cat /sys/kernel/debug/kvm/$f 2>/dev/null || echo NA)
    echo "$f=$v"
  done
}

echo "=== ISOLATE $TAG ARM=$ARM threads=$THREADS secs=$SECS $(date) ===" | tee "$OUT"
echo "--- halt-counters BEFORE ---" | tee -a "$OUT"
snap | tee -a "$OUT"
T0=$(date +%s.%N)

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
  -append '--norandom --nomount --noinit $ENV_APPEND --preload-zfs-library /zfs-bench.so syncwrite pool=bench vdevs=/dev/vblk1 threads=$THREADS secs=$SECS reps=3 recsize=8k'
  rc=\$?
  rm -f \$THROW
  echo \"== qemu exit rc=\$rc ==\"
" 2>&1 | tee -a "$OUT"

T1=$(date +%s.%N)
echo "--- halt-counters AFTER ---" | tee -a "$OUT"
snap | tee -a "$OUT"
DUR=$(echo "$T1 - $T0" | bc)
echo "WALL_DUR_S=$DUR" | tee -a "$OUT"
echo "=== ISOLATE $TAG DONE $(date) ===" | tee -a "$OUT"
