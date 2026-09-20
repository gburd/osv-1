#!/bin/bash
set -x
cd /work/osv || exit 1
exec > /work/clean-rebuild.log 2>&1
NPROC=$(nproc)
# nuke openzfs objects + elf to force a clean, correctly-ordered compile
sudo docker exec bld bash -lc 'cd /work/osv && rm -rf build/release.x64/modules/open_zfs build/release.x64/zfs_builder.elf build/release.x64/zfs_builder_bootfs.* build/release.x64/libsolaris.so build/release.x64/zpool.so build/release.x64/zfs.so'
ZFSSOS="libsolaris.so zpool.so zfs.so libzfs.so libuutil.so libzfs_core.so libzutil.so libshare.so libtpool.so"
OUTDIR=build/release.x64; TGTS=""; for s in $ZFSSOS; do TGTS="$TGTS $OUTDIR/$s"; done
sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs $TGTS" 2>&1 | tail -8
echo "SO_RC=$?"
sudo docker exec bld bash -lc "cd /work/osv && bash scripts/bench/rebuild-bench.sh openzfs" 2>&1 | tail -10
echo "BENCH_RC=$?"
ls -l "$OUTDIR/zfs_builder.elf" "$OUTDIR/zfs-bench.so" 2>&1
grep -c "RESULT ZILCOMMIT" modules/open_zfs/openzfs/module/zfs/zil.c
echo CLEAN_REBUILD_DONE
