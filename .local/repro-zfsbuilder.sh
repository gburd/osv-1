#!/usr/bin/env bash
# Isolate the in-guest ZFS-builder step so we can watch the guest console and
# vary pool size + guest RAM without rerunning the whole scripts/build.
#
# Usage: repro-zfsbuilder.sh <fs_size_mb> <guest_mem_mb>
set -uo pipefail

FS_SIZE_MB=${1:-2048}
GUEST_MEM=${2:-2048}

cd /scratch/gburd/ozfs-mmap
OUT=build/last
SRC=$(pwd)

fs_size=$((FS_SIZE_MB * 1024 * 1024))
fs_size=$((fs_size - (fs_size & 511)))

# Mirror create_zfs_disk(): loader.img -> raw, set partition, resize, convert to qcow2.
loader_size=$(stat --printf %s "$OUT/loader.img")
kernel_end=$(((loader_size + 2097151) & ~2097151))
partition_offset=$kernel_end
partition_size=$((fs_size - partition_offset))
image_size=$fs_size

rm -f "$OUT/repro.raw" "$OUT/repro.img"
cp "$OUT/loader.img" "$OUT/repro.raw"
"$SRC"/scripts/imgedit.py setpartition "-f raw $OUT/repro.raw" 2 "$partition_offset" "$partition_size"
qemu-img convert -f raw -O qcow2 "$OUT/repro.raw" "$OUT/repro.img"
qemu-img resize "$OUT/repro.img" "${image_size}b" >/dev/null 2>&1
rm -f "$OUT/repro.raw"

echo "=== repro: pool=${FS_SIZE_MB}MiB guest_mem=${GUEST_MEM}MiB ==="
qemu-img info "$OUT/repro.img" | grep -E "virtual size|disk size"

# Run the EXACT real builder cmdline (mkfs + cpiod listen). We only care whether
# mkfs completes and cpiod prints "Waiting for connection" (host connects there).
# No host cpio client here; time out after 90s so we see how far the guest gets.
timeout 90 scripts/run.py -k --kernel-path build/last/zfs_builder-stripped.elf \
  --arch=x86_64 --vnc none -m "${GUEST_MEM}" -c1 -i "$OUT/repro.img" \
  --block-device-cache unsafe -s \
  -e "--console=serial --norandom --nomount --noinit --preload-zfs-library /tools/mkfs.so; /tools/cpiod.so --prefix /zfs/zfs/; /zfs.so set compression=off osv" 2>&1 | sed 's/^/[guest] /'
rc=$?
echo "=== repro exit rc=$rc ==="
rm -f "$OUT/repro.img"
