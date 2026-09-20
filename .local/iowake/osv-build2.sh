#!/bin/bash
# Re-run just the OSv ZFS .so + zfs_builder.elf build (submodules now complete).
set -x
exec > /home/ec2-user/osv-build2.log 2>&1
echo "=== START $(date) ==="
cd /home/ec2-user/osv
NPROC=$(nproc)
OUTDIR=build/release.x64
ZFSSOS="libsolaris.so zpool.so zfs.so libzfs.so libuutil.so libzfs_core.so libzutil.so libshare.so libtpool.so"
TGTS=""; for s in $ZFSSOS; do TGTS="$TGTS $OUTDIR/$s"; done
sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs OSV_NO_JAVA_TESTS=1 $TGTS" 2>&1 | tail -30
echo "ZFS_SO_RC=${PIPESTATUS[0]}"
ls -l $OUTDIR/libsolaris.so $OUTDIR/zpool.so $OUTDIR/zfs.so 2>&1 | head

sudo docker exec bld bash -lc "cd /work/osv && bash scripts/bench/rebuild-bench.sh openzfs" 2>&1 | tail -25
echo "BENCH_RC=${PIPESTATUS[0]}"

echo "=== ARTIFACTS ==="
ls -l $OUTDIR/zfs_builder.elf $OUTDIR/zfs-bench.so $OUTDIR/zpool.so $OUTDIR/zfs.so 2>&1
echo "=== END $(date) ==="
echo OSV_BUILD2_DONE
