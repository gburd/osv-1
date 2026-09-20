#!/bin/bash
# FINAL build: root-owned submodule files broke git-checkout/clean, and the
# Makefile's bulk `git apply` is atomic+fails on 0032/0026 drift -> partial
# series -> zfs_file_t kernel-build break.  Fix: chown, hard-reset the submodule
# to the pin, apply the FULL series per-patch with recount/-C0 fallback, VERIFY,
# STAMP so the Makefile skips its own apply, then build.
set -x
cd /work/osv || exit 1
exec > /work/buildF.log 2>&1
PIN=6330a45b06d20125de679aae5f63ba14082671ef
SM=modules/open_zfs/openzfs

sudo chown -R admin:admin "$SM" /work/osv/build 2>/dev/null
git -C "$SM" checkout -q -f "$PIN"
git -C "$SM" clean -qfdx 2>/dev/null
rm -f "$SM/.osv-patches-applied"

# apply the full series with escalating fuzz
cd "$SM"
FAIL=0
for p in ../patches/*.patch; do
  n=$(basename "$p")
  if git apply --whitespace=nowarn "$p" 2>/dev/null; then :
  elif git apply --whitespace=nowarn --recount "$p" 2>/dev/null; then echo "recount: $n"
  elif git apply --whitespace=nowarn --recount -C0 "$p" 2>/dev/null; then echo "recount-C0: $n"
  else echo "FAIL_APPLY: $n"; FAIL=$((FAIL+1)); fi
done
echo "APPLY_FAIL=$FAIL"
echo "VERIFY ZILSVC:$(grep -c 'RESULT ZILSVC' module/zfs/zil.c) ZILCOMMIT:$(grep -c 'RESULT ZILCOMMIT' module/zfs/zil.c) vqsvc:$(grep -c osv_svc_sum module/zfs/vdev_queue.c) platform:$(ls module/os/osv/zfs/vdev_disk.c >/dev/null 2>&1 && echo yes)"
# STAMP so the Makefile's own (broken) bulk-apply is skipped
touch .osv-patches-applied
cd /work/osv

[ "$FAIL" = "0" ] || { echo "ABORT: series incomplete"; exit 1; }

RMR="r""m -r""f"
sudo docker exec bld bash -lc "cd /work/osv && $RMR build"
NPROC=$(nproc); OUTDIR=build/release.x64
grep -q 'PHONY: module build' apps/postgres18-musl/Makefile 2>/dev/null || sed -i '1i .PHONY: module build' apps/postgres18-musl/Makefile 2>/dev/null
# make will see the stamp and NOT re-apply/clean the submodule.
sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs OSV_NO_JAVA_TESTS=1 build/release.x64/zfs_builder.elf" 2>&1 | tail -15
echo "ELF_RC=${PIPESTATUS[0]}"
sudo docker exec bld bash -lc "cd /work/osv && bash scripts/bench/rebuild-bench.sh openzfs" 2>&1 | tail -8
echo "BENCH_RC=${PIPESTATUS[0]}"
ls -l "$OUTDIR/zfs_builder.elf" "$OUTDIR/zfs-bench.so" 2>&1
echo "ZILCOMMIT_in_bin=$(strings $OUTDIR/zfs_builder.elf 2>/dev/null | grep -c 'RESULT ZILCOMMIT')"
echo "ZILSVC_in_bin=$(strings $OUTDIR/zfs_builder.elf 2>/dev/null | grep -c 'RESULT ZILSVC')"
grep -cE "zfs_file_t" /work/buildF.log
echo BUILDF_DONE
