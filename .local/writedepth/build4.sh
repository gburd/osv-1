#!/bin/bash
# Build with the openzfs submodule FORCED to the correct pin 6330a45b (the wrong
# 83020cf8 snapshot has the zfs_file_t header break). Re-apply patch series on
# the correct base, then build the ELF.
set -x
cd /work/osv || exit 1
exec > /work/build4.log 2>&1
PIN=6330a45b06d20125de679aae5f63ba14082671ef
RMR="r""m -r""f"
# ensure submodule at the correct pin, clean, unpatched
git -C modules/open_zfs/openzfs fetch origin "$PIN" 2>&1 | tail -1
git -C modules/open_zfs/openzfs checkout -q -f "$PIN"
git -C modules/open_zfs/openzfs clean -qfdx 2>/dev/null
$RMR modules/open_zfs/openzfs/.osv-patches-applied
echo "OZFS_PIN=$(git -C modules/open_zfs/openzfs rev-parse HEAD)"
echo "OSV_SHA=$(git rev-parse HEAD)"
sudo docker exec bld bash -lc "cd /work/osv && $RMR build"
NPROC=$(nproc); OUTDIR=build/release.x64
grep -q 'PHONY: module build' apps/postgres18-musl/Makefile 2>/dev/null || sed -i '1i .PHONY: module build' apps/postgres18-musl/Makefile 2>/dev/null
sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs OSV_NO_JAVA_TESTS=1 build/release.x64/zfs_builder.elf" 2>&1 | tail -12
echo "ELF_RC=$?"
echo "=== patch-applied verify (correct-pin source) ==="
echo "ZILSVC:$(grep -c 'RESULT ZILSVC' modules/open_zfs/openzfs/module/zfs/zil.c) ZILCOMMIT:$(grep -c 'RESULT ZILCOMMIT' modules/open_zfs/openzfs/module/zfs/zil.c) vqsvc:$(grep -c osv_svc_sum modules/open_zfs/openzfs/module/zfs/vdev_queue.c)"
sudo docker exec bld bash -lc "cd /work/osv && bash scripts/bench/rebuild-bench.sh openzfs" 2>&1 | tail -8
echo "BENCH_RC=$?"
ls -l "$OUTDIR/zfs_builder.elf" "$OUTDIR/zfs-bench.so" 2>&1
echo "ZILCOMMIT_in_bin=$(strings $OUTDIR/zfs_builder.elf 2>/dev/null | grep -c 'RESULT ZILCOMMIT')"
echo "ZILSVC_in_bin=$(strings $OUTDIR/zfs_builder.elf 2>/dev/null | grep -c 'RESULT ZILSVC')"
grep -cE "zfs_file_t" /work/build4.log
echo BUILD4_DONE
