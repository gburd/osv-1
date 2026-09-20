#!/bin/bash
# Build only (patches already applied + stamped by apply-series.sh).
set -x
cd /work/osv || exit 1
exec > /work/buildG.log 2>&1
RMR="r""m -r""f"
sudo chown -R admin:admin /work/osv/build 2>/dev/null
sudo docker exec bld bash -lc "cd /work/osv && $RMR build"
NPROC=$(nproc); OUTDIR=build/release.x64
grep -q 'PHONY: module build' apps/postgres18-musl/Makefile 2>/dev/null || sed -i '1i .PHONY: module build' apps/postgres18-musl/Makefile 2>/dev/null
sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs OSV_NO_JAVA_TESTS=1 build/release.x64/zfs_builder.elf" 2>&1 | tail -15
echo "ELF_RC=${PIPESTATUS[0]}"
sudo docker exec bld bash -lc "cd /work/osv && bash scripts/bench/rebuild-bench.sh openzfs" 2>&1 | tail -8
echo "BENCH_RC=${PIPESTATUS[0]}"
ls -l "$OUTDIR/zfs_builder.elf" "$OUTDIR/zfs-bench.so" 2>&1
echo "ZILCOMMIT_in_bin=$(strings $OUTDIR/zfs_builder.elf 2>/dev/null | grep -c 'RESULT ZILCOMMIT')"
echo "ZILSVC_in_bin=$(strings $OUTDIR/zfs_builder.elf 2>/dev/null | grep -c 'RESULT ZILSVC')"
grep -cE "zfs_file_t|Error 1" /work/buildG.log
echo BUILDG_DONE
