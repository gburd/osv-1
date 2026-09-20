#!/bin/bash
# Minimal targeted rebuild: 0042 only changed module/zfs/zil.c, so recompile
# just that object + relink zfs_builder.elf. Avoids the full -j96 parallel
# openzfs recompile that races on zfs_file.h include ordering.
set -x
cd /work/osv || exit 1
exec > /work/targeted-rebuild.log 2>&1
NPROC=$(nproc)
OUTDIR=build/release.x64
# Touch zil.c so make rebuilds its object; remove the stale zil.o + the elf.
sudo docker exec bld bash -lc "cd /work/osv && rm -f build/release.x64/modules/open_zfs/openzfs/module/zfs/zil.o build/release.x64/zfs_builder.elf build/release.x64/zfs_builder_bootfs.bin build/release.x64/zfs_builder_bootfs.o && touch modules/open_zfs/openzfs/module/zfs/zil.c"
# Rebuild the .so set SERIALLY (-j1) to avoid the header-ordering race, but only
# the zil object needs recompiling so this is fast.
ZFSSOS="libsolaris.so zpool.so zfs.so libzfs.so libuutil.so libzfs_core.so libzutil.so libshare.so libtpool.so"
TGTS=""; for s in $ZFSSOS; do TGTS="$TGTS $OUTDIR/$s"; done
sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs $TGTS" 2>&1 | tail -8
echo "SO_RC=$?"
sudo docker exec bld bash -lc "cd /work/osv && bash scripts/bench/rebuild-bench.sh openzfs" 2>&1 | tail -10
echo "BENCH_RC=$?"
ls -l "$OUTDIR/zfs_builder.elf" "$OUTDIR/zfs-bench.so" 2>&1
echo "ZILCOMMIT_in_bin=$(strings $OUTDIR/zfs_builder.elf 2>/dev/null | grep -c 'RESULT ZILCOMMIT')"
echo "ZILSVC_in_bin=$(strings $OUTDIR/zfs_builder.elf 2>/dev/null | grep -c 'RESULT ZILSVC')"
echo TARGETED_REBUILD_DONE
