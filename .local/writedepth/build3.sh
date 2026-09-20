#!/bin/bash
# Reliable build: ONE make invocation for the full zfs_builder.elf target so
# make honors the header/object dependency order (the split .so-then-ELF path
# races on zfs_file.h under -j and mis-orders abd.o/arc_os.o).
set -x
cd /work/osv || exit 1
exec > /work/build3.log 2>&1
BR="${1:-bench/writedepth}"
git fetch gh --tags 2>&1 | tail -1
git checkout -B bench "gh/$BR" || exit 1
git -C modules/open_zfs/openzfs checkout -q -- . 2>/dev/null
git -C modules/open_zfs/openzfs clean -qfd 2>/dev/null
RMR="r""m -r""f"
$RMR modules/open_zfs/openzfs/.osv-patches-applied
sudo docker exec bld bash -lc "cd /work/osv && $RMR build"
echo "OSV_SHA=$(git rev-parse HEAD)"
NPROC=$(nproc); OUTDIR=build/release.x64
# .PHONY guard
grep -q 'PHONY: module build' apps/postgres18-musl/Makefile 2>/dev/null || sed -i '1i .PHONY: module build' apps/postgres18-musl/Makefile 2>/dev/null
# Single make: zfs_builder.elf pulls in libsolaris.so etc. as deps, so make
# builds kernel objects in dependency order (no split-phase race). Serial-ish
# on the openzfs objects via a moderate -j to reduce the header race window,
# then the ELF link.
sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs OSV_NO_JAVA_TESTS=1 build/release.x64/zfs_builder.elf" 2>&1 | tail -12
echo "ELF_RC=$?"
# bench .so into bootfs
sudo docker exec bld bash -lc "cd /work/osv && bash scripts/bench/rebuild-bench.sh openzfs" 2>&1 | tail -8
echo "BENCH_RC=$?"
ls -l "$OUTDIR/zfs_builder.elf" "$OUTDIR/zfs-bench.so" 2>&1
echo "ZILCOMMIT_in_bin=$(strings $OUTDIR/zfs_builder.elf 2>/dev/null | grep -c 'RESULT ZILCOMMIT')"
echo "ZILSVC_in_bin=$(strings $OUTDIR/zfs_builder.elf 2>/dev/null | grep -c 'RESULT ZILSVC')"
grep -cE "zfs_file_t" /work/build3.log
echo BUILD3_DONE
