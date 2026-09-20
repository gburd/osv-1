#!/bin/bash
# walwake syncwrite-mt run: boot zfs_builder.elf under QEMU/KVM in fedora:39,
# instance-store NVMe /dev/nvme1n1 as virtio-blk (vblk1), run zfs-bench.so
# syncwrite. 32 vCPU / 64 GiB guest so 32-thread concurrency is real.
# -M pc (fedora qemu 8.1.3). vblk0 = throwaway 64M; real NVMe = vblk1.
# Args: <outfile> <workload+kv...>   env: SMP (default 32), MEM (default 64G),
# TIMEOUT (default 300), ENV_APPEND (extra --env=... for A/B), IOSTAT=1 (start
# host iostat on nvme1 during the run), TOPH=1 (capture host top -H vCPU busy).
set -x
OUT="$1"; shift
WLKV="$*"
ELF=/work/osv/build/release.x64/zfs_builder.elf
TIMEOUT="${TIMEOUT:-300}"
SMP="${SMP:-32}"
MEM="${MEM:-64G}"
ENV_APPEND="${ENV_APPEND:-}"

# Optional host instrumentation, started just before the guest boots.
if [ "${IOSTAT:-0}" = "1" ]; then
  ( iostat -x 1 60 nvme1n1 > /home/ec2-user/iostat-$(basename "$OUT").txt 2>&1 ) &
  IOSTAT_BG=$!
fi
if [ "${TOPH:-0}" = "1" ]; then
  ( for i in $(seq 1 30); do
      echo "=== t=$i $(date +%s) ==="
      top -H -b -n1 | grep -iE 'qemu|CPU' | head -60
      sleep 2
    done > /home/ec2-user/toph-$(basename "$OUT").txt 2>&1 ) &
  TOPH_BG=$!
fi

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
  -append '--norandom --nomount --noinit $ENV_APPEND --preload-zfs-library /zfs-bench.so $WLKV'
  rc=\$?
  rm -f \$THROW
  echo \"== qemu exit rc=\$rc ==\"
" 2>&1 | tee "$OUT"

[ -n "${IOSTAT_BG:-}" ] && kill $IOSTAT_BG 2>/dev/null
[ -n "${TOPH_BG:-}" ] && kill $TOPH_BG 2>/dev/null
true
