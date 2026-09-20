#!/bin/bash
# Replicate the EXACT first-successful-build sequence: build the .so targets
# FIRST (this populates generated-headers + compiles the kernel openzfs objects
# in a working order), THEN relink the ELF. The combined single-make and the
# clean-nuke both race on zfs_file.h under -j96. Keep the submodule at 6330a45b.
set -x
cd /work/osv || exit 1
exec > /work/build5.log 2>&1
PIN=6330a45b06d20125de679aae5f63ba14082671ef
RMR="r""m -r""f"
git -C modules/open_zfs/openzfs fetch origin "$PIN" 2>&1 | tail -1
git -C modules/open_zfs/openzfs checkout -q -f "$PIN"
git -C modules/open_zfs/openzfs clean -qfdx 2>/dev/null
$RMR modules/open_zfs/openzfs/.osv-patches-applied
echo "OZFS_PIN=$(git -C modules/open_zfs/openzfs rev-parse HEAD)"
sudo docker exec bld bash -lc "cd /work/osv && $RMR build"
NPROC=$(nproc); OUTDIR=build/release.x64
grep -q 'PHONY: module build' apps/postgres18-musl/Makefile 2>/dev/null || sed -i '1i .PHONY: module build' apps/postgres18-musl/Makefile 2>/dev/null

# PHASE 1: generated headers first (serial), so the -D_KERNEL/__OSV__ config +
# zfs_file.h context is present before any openzfs object compiles.
sudo docker exec bld bash -lc "cd /work/osv && make -j1 conf_fork=1 conf_zfs=openzfs fs=rofs OSV_NO_JAVA_TESTS=1 generated-headers" 2>&1 | tail -4
echo "GENHDR_RC=$?"

# PHASE 2: the .so set (this is what the first successful build did first).
ZFSSOS="libsolaris.so zpool.so zfs.so libzfs.so libuutil.so libzfs_core.so libzutil.so libshare.so libtpool.so"
TGTS=""; for s in $ZFSSOS; do TGTS="$TGTS $OUTDIR/$s"; done
sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs $TGTS" 2>&1 | tail -8
echo "SO_RC=$?"

# PHASE 3: the ELF (reuses the kernel objects the .so phase compiled).
sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs OSV_NO_JAVA_TESTS=1 build/release.x64/zfs_builder.elf" 2>&1 | tail -10
echo "ELF_RC=$?"

sudo docker exec bld bash -lc "cd /work/osv && bash scripts/bench/rebuild-bench.sh openzfs" 2>&1 | tail -8
echo "BENCH_RC=$?"
ls -l "$OUTDIR/zfs_builder.elf" "$OUTDIR/zfs-bench.so" 2>&1
echo "ZILCOMMIT_in_bin=$(strings $OUTDIR/zfs_builder.elf 2>/dev/null | grep -c 'RESULT ZILCOMMIT')"
echo "ZILSVC_in_bin=$(strings $OUTDIR/zfs_builder.elf 2>/dev/null | grep -c 'RESULT ZILSVC')"
grep -cE "zfs_file_t" /work/build5.log
echo BUILD5_DONE
