#!/bin/bash
# GENUINELY-IDLE regression check (runs ON the metal host).
# 1 writer thread on a 32-vCPU guest => 31 vCPUs mostly idle. Their do_idle
# loops decide spin-vs-halt. FIXED (cap pinned) spins the full window every idle
# entry on all idle vCPUs (burns host CPU); ADAPTIVE decays to the floor + halts.
# Measure host qemu %CPU during the steady phase. GATE: adaptive must NOT burn
# materially more host CPU at idle than fixed.
# Args: <tag> <arm>  (arm=adaptive|fixed)  env SECS default 40
set -u
TAG="$1"; ARM="$2"; SECS="${SECS:-40}"
OUT=/scratch/idle-$TAG-$ARM.txt
QLOG=/scratch/qi-$TAG-$ARM.log

if [ "$ARM" = fixed ]; then IDLEENV="--env=OSV_IDLE_SPIN_ADAPTIVE=0"; else IDLEENV=""; fi
ENVS="$IDLEENV --env=OSV_WAKE_PULL=1 --env=OSV_ZFS_ARC_MAX=34359738368 --env=OSV_BLK_MQ_COMPLETE=1"

cat > /scratch/qi-$TAG-$ARM.sh <<EOF
#!/bin/bash
cd /work/osv
pkill -9 -f qemu-system-x86 2>/dev/null; sleep 1
THROW=\$(mktemp /tmp/vblk0.XXXX.img); qemu-img create -f raw \$THROW 64M >/dev/null 2>&1
timeout $((SECS + 100)) qemu-system-x86_64 -M pc -cpu host -enable-kvm -nographic -no-reboot -m 64G -smp 32 \
  -kernel /work/osv/build/release.x64/zfs_builder.elf \
  -device virtio-blk-pci,id=blk0,drive=hd0 \
  -drive file=\$THROW,if=none,id=hd0,format=raw,cache=writeback,aio=threads \
  -device virtio-blk-pci,id=blk1,drive=hd1 \
  -drive file=/dev/nvme1n1,if=none,id=hd1,format=raw,cache=none,aio=native \
  -append "--norandom --nomount --noinit $ENVS --preload-zfs-library /zfs-bench.so syncwrite pool=bench vdevs=/dev/vblk1 threads=1 secs=$SECS reps=1 recsize=8k" > /work/qi-$TAG-$ARM.log 2>&1
echo "DONERC=\$?" >> /work/qi-$TAG-$ARM.log
rm -f \$THROW
EOF

echo "=== IDLE-REGRESSION $TAG ARM=$ARM (1 writer, 31 idle vCPUs) secs=$SECS $(date) ===" | tee "$OUT"
echo "ENVS: $ENVS" | tee -a "$OUT"
rm -f "$QLOG" /scratch/idlecpu-$TAG-$ARM.samples
sudo docker exec -d bld bash /work/qi-$TAG-$ARM.sh

# sample host qemu %CPU (sum over threads) during steady phase (skip first 12s)
( sleep 12
  for i in $(seq 1 $((SECS/2))); do
    P=$(pgrep -f 'qemu-system-x86_64 -M pc' | head -1)
    [ -z "$P" ] && { echo "t=$i no-qemu"; sleep 2; continue; }
    CPU=$(top -b -n1 -H -p "$P" 2>/dev/null | awk 'NR>7{s+=$9} END{printf "%.1f", s}')
    echo "t=$i qemu_pct_cpu=$CPU"
    sleep 2
  done > /scratch/idlecpu-$TAG-$ARM.samples 2>&1 ) &
SAMP=$!

for i in $(seq 1 $((SECS*3 + 200))); do grep -q '^DONERC=' "$QLOG" 2>/dev/null && break; sleep 2; done
kill $SAMP 2>/dev/null; wait $SAMP 2>/dev/null

{
echo "--- idle-cpu samples (host qemu %CPU, sum over vCPU threads) ---"
cat /scratch/idlecpu-$TAG-$ARM.samples
MED=$(awk -F= '/qemu_pct_cpu=/{print $NF}' /scratch/idlecpu-$TAG-$ARM.samples | grep -v '^$' | sort -n | awk '{a[NR]=$1} END{if(NR)print (NR%2)?a[(NR+1)/2]:(a[int(NR/2)]+a[int(NR/2)+1])/2; else print "NA"}')
echo "IDLE_QEMU_PCT_CPU_MEDIAN=$MED"
echo "--- bench (1 thread) ---"
grep -E 'RESULT syncwrite_mt_persec|wake2ent|DONERC' "$QLOG" 2>/dev/null
echo "=== IDLE-REGRESSION $TAG ARM=$ARM DONE $(date) ==="
} | tee -a "$OUT"
