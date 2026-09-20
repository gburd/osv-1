#!/bin/bash
# syncwrite-mt isolate A/B driver (runs ON the metal host). For each ARM, writes
# a per-arm qtest script into the container, runs it detached, polls the log to
# completion, and snapshots host KVM halt counters around the run.
#   ARM adaptive = default (adaptive spin); ARM fixed = OSV_IDLE_SPIN_ADAPTIVE=0.
# Args: <tag> <threads> <secs> <arm>
set -u
TAG="$1"; THREADS="$2"; SECS="$3"; ARM="$4"
OUT=/scratch/isolate-$TAG-$ARM.txt
QLOG=/scratch/q-$TAG-$ARM.log

if [ "$ARM" = fixed ]; then
  IDLEENV="--env=OSV_IDLE_SPIN_ADAPTIVE=0"
else
  IDLEENV=""
fi
ENVS="$IDLEENV --env=OSV_WAKE_PULL=1 --env=OSV_ZFS_ARC_MAX=34359738368 --env=OSV_BLK_MQ_COMPLETE=1"

snap() {
  for f in halt_exits halt_successful_poll halt_attempted_poll halt_poll_invalid halt_wakeup; do
    printf "%s=%s\n" "$f" "$(sudo cat /sys/kernel/debug/kvm/$f 2>/dev/null || echo NA)"
  done
}

cat > /scratch/q-$TAG-$ARM.sh <<EOF
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
  -append "--norandom --nomount --noinit $ENVS --preload-zfs-library /zfs-bench.so syncwrite pool=bench vdevs=/dev/vblk1 threads=$THREADS secs=$SECS reps=3 recsize=8k" > /work/q-$TAG-$ARM.log 2>&1
echo "DONERC=\$?" >> /work/q-$TAG-$ARM.log
rm -f \$THROW
EOF

{
echo "=== ISOLATE $TAG ARM=$ARM threads=$THREADS secs=$SECS reps=3 $(date) ==="
echo "ENVS: $ENVS"
echo "--- halt-counters BEFORE ---"; snap
} | tee "$OUT"
T0=$(date +%s)

rm -f "$QLOG" /scratch/halt-$TAG-$ARM.samples
sudo docker exec -d bld bash /work/q-$TAG-$ARM.sh
# Sample halt counters WHILE the VM is alive (debugfs aggregate zeroes once the
# last VM exits, so before/after is useless -- take the peak-while-running).
( for i in $(seq 1 $((SECS*3 + 200))); do
    pgrep -f 'qemu-system-x86_64 -M pc' >/dev/null 2>&1 || { grep -q '^DONERC=' "$QLOG" 2>/dev/null && break; }
    he=$(sudo cat /sys/kernel/debug/kvm/halt_exits 2>/dev/null || echo 0)
    hsp=$(sudo cat /sys/kernel/debug/kvm/halt_successful_poll 2>/dev/null || echo 0)
    hap=$(sudo cat /sys/kernel/debug/kvm/halt_attempted_poll 2>/dev/null || echo 0)
    echo "t=$i halt_exits=$he halt_successful_poll=$hsp halt_attempted_poll=$hap"
    sleep 2
  done > /scratch/halt-$TAG-$ARM.samples 2>&1 ) &
SAMP=$!
# poll to completion (bench prints DONERC when finished)
for i in $(seq 1 $((SECS*3 + 200))); do
  grep -q '^DONERC=' "$QLOG" 2>/dev/null && break
  sleep 2
done
kill $SAMP 2>/dev/null; wait $SAMP 2>/dev/null
T1=$(date +%s)

# peak (last nonzero) halt counters while VM was alive
PEAK=$(grep halt_exits= /scratch/halt-$TAG-$ARM.samples 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /halt_exits=/){split($i,a,"="); if(a[2]+0>m)m=a[2]+0}} END{print m+0}')
PEAKSP=$(grep halt_successful_poll= /scratch/halt-$TAG-$ARM.samples 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /halt_successful_poll=/){split($i,a,"="); if(a[2]+0>m)m=a[2]+0}} END{print m+0}')

{
echo "--- halt-counters PEAK-WHILE-ALIVE ---"
echo "halt_exits_peak=$PEAK"
echo "halt_successful_poll_peak=$PEAKSP"
echo "WALL_DUR_S=$((T1 - T0))"
echo "halt_exits_per_s=$(awk "BEGIN{d=$((T1-T0)); print (d>0)?$PEAK/d:0}")"
echo "--- bench output ---"
grep -E 'RESULT syncwrite_mt|wake2ent|ZILWAIT|ZILWAKE2|DONERC' "$QLOG" 2>/dev/null
echo "=== ISOLATE $TAG ARM=$ARM DONE $(date) ==="
} | tee -a "$OUT"
