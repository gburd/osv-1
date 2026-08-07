#!/bin/bash
# 20-osv-mkpool-initdb.sh -- one-shot OSv boot: create ZFS pool on the virtio-blk
# backing, initdb the PG cluster into it (musl locale-safe), export. Runs in the
# fedora qemu container. Produces /mnt/nvme/pgdata-osv.raw with a ready cluster.
set -u
SMP="${SMP:-8}"
MEM="${MEM:-16G}"
SCALE="${SCALE:-20}"
OSV=/mnt/nvme/osv-img
IMG=$OSV/usr.img
KERNEL=$OSV/loader.elf
PGBIN=/b/.local/pg18/install/bin   # baked into the ramfs rootfs
BLK=/mnt/nvme/pgdata-osv.raw

# fresh 80G backing file
rm -f "$BLK"; truncate -s 80G "$BLK"

# create pool, initdb (musl: builtin C locale, per hammer2 gotcha), open HBA, export.
CREATE="/zpool.so create -f -o ashift=12 -O compression=lz4 -O atime=off -O recordsize=8k -m /data pgdata /dev/vblk1"
INITDB="$PGBIN/initdb -D /data -U postgres --locale-provider=builtin --builtin-locale=C -E UTF8"
HBA="echo host all all 0.0.0.0/0 trust >> /data/pg_hba.conf ; echo local all all trust >> /data/pg_hba.conf"
INIT="$CREATE ; $INITDB ; $HBA ; /zpool.so export pgdata"
APPEND="--rootfs=ramfs $INIT"

rm -f /tmp/osv-init.log
echo "== OSv mkpool+initdb (SMP=$SMP MEM=$MEM) =="
timeout 300 qemu-system-x86_64 -machine pc -accel tcg,thread=multi -cpu max -m "$MEM" -smp "$SMP" \
  -nographic -no-reboot \
  -kernel "$KERNEL" -append "$APPEND" \
  -device virtio-blk-pci,id=blk0,drive=hd0 -drive "file=$IMG,if=none,id=hd0,cache=writeback,aio=threads" \
  -device virtio-blk-pci,id=blk1,drive=hd1 -drive "file=$BLK,if=none,id=hd1,format=raw,cache=none,aio=native" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  2>&1 | tee /tmp/osv-init.log | grep -viE "iPXE|SeaBIOS"
echo "== initdb exit; pool exported =="
grep -qiE "Success|ready|export" /tmp/osv-init.log && echo OSV_INITDB_OK || echo OSV_INITDB_CHECK
