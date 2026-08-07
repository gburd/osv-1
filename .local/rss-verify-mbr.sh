#!/bin/bash
# rss-verify-mbr.sh -- boot the baked image via MBR (NO -kernel), mimicking the AMI/Nitro
# boot path where OSv reads cmdline from offset 512. Confirms offset-512 cmdline + DEFAULT mmap.
set -u
docker run --rm --privileged --device /dev/kvm \
  -v /mnt/nvme/osv:/b -v /mnt/nvme:/mnt/nvme fedora:39 bash -c '
set -u
dnf install -y -q qemu-system-x86 postgresql >/tmp/dnf.log 2>&1 || { tail /tmp/dnf.log; exit 1; }
IMG=/mnt/nvme/osv-img/ami-usr.img
BLK=/mnt/nvme/pgdata-osv.raw
rm -f /tmp/osvm.log
# NO -kernel: qemu boots the disk MBR (boot16.S) -> loader reads cmdline @offset 512.
nohup qemu-system-x86_64 -machine pc -accel kvm -cpu host -m 16G -smp 8 -nographic -no-reboot \
  -device virtio-blk-pci,id=blk0,drive=hd0 -drive "file=$IMG,if=none,id=hd0,cache=writeback,aio=threads,format=raw" \
  -device virtio-blk-pci,id=blk1,drive=hd1 -drive "file=$BLK,if=none,id=hd1,format=raw,cache=none,aio=native" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:5432-:5432" -device virtio-net-pci,netdev=n0 \
  > /tmp/osvm.log 2>&1 &
QPID=$!
READY=0
for i in $(seq 1 150); do
  sleep 1
  grep -q "ready to accept" /tmp/osvm.log 2>/dev/null && { echo "NATIVE_MBR_READY ${i}s"; READY=1; break; }
  grep -qiE "Aborted|panic|Assertion failed|empty command line" /tmp/osvm.log && { echo "NATIVE_MBR_FAIL:"; tail -20 /tmp/osvm.log|grep -vE "iPXE|SeaBIOS"; break; }
done
echo "=== boot log ==="
grep -E "Cmdline:|Booted up|ready to accept|eth0:|Pool .pgdata|empty command" /tmp/osvm.log | head
if [ "$READY" = 1 ]; then
  for t in 1 2 3 4 5; do
    OUT=$(psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -tAc "select 1" 2>&1)
    echo "[try$t] $OUT"; echo "$OUT"|grep -qx 1 && { echo NATIVE_MBR_SERVE_OK; break; }; sleep 3
  done
else
  echo NATIVE_MBR_NOTREADY; tail -30 /tmp/osvm.log|grep -vE "iPXE|SeaBIOS"
fi
kill $QPID 2>/dev/null
'
