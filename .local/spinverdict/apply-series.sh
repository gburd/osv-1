#!/bin/bash
# Robust patch-apply for the OSv-openzfs series onto pin 6330a45b.
# Root cause of the build breaks this run:
#  (1) root-owned submodule files (from sudo docker) blocked git checkout/clean.
#  (2) the Makefile bulk `git apply` is atomic and 0032 has drifted context, so
#      it applied only a PARTIAL series -> kernel build broke.
#  (3) `--recount -C0` on 0032 mis-placed its prototype hunk -> compile error.
# Fix: chown, hard-reset, apply per-patch with recount fallback, and apply 0032's
# zfs_initialize_osv.c prototype via an EXACT anchor (python) so placement is right.
set -e
SM=/work/osv/modules/open_zfs/openzfs
PIN=6330a45b06d20125de679aae5f63ba14082671ef
sudo chown -R admin:admin "$SM"
cd "$SM"
git checkout -q -f "$PIN"; git clean -qfdx; rm -f .osv-patches-applied

for p in ../patches/*.patch; do
  n=$(basename "$p")
  case "$n" in
    0032-*)
      # arc.c hunk: recount is fine. zfs_initialize_osv.c: apply arc.c part,
      # then fix the prototype placement exactly.
      # Split: apply the whole patch with recount; if the prototype landed
      # wrong (used before declared), repair via python exact-anchor.
      git apply --whitespace=nowarn --recount "$p" 2>/dev/null || \
      git apply --whitespace=nowarn --recount -C0 "$p" 2>/dev/null || echo "FAIL_APPLY $n"
      python3 - <<'PY'
f = "module/os/osv/zfs/zfs_initialize_osv.c"
s = open(f).read()
proto = "extern uint64_t arc_reduce_target_size_shrink_sync(uint64_t to_free);\n"
anchor = "extern uint64_t arc_reduce_target_size_noshrink(uint64_t to_free);\n"
# ensure the shrink_sync prototype sits right after the noshrink one, exactly once
s = s.replace(proto, "")  # drop any mis-placed copy
assert s.count(anchor) == 1, ("anchor", s.count(anchor))
s = s.replace(anchor, anchor + proto, 1)
open(f, "w").write(s)
print("0032 prototype placement fixed")
PY
      ;;
    *)
      git apply --whitespace=nowarn "$p" 2>/dev/null || \
      git apply --whitespace=nowarn --recount "$p" 2>/dev/null || \
      git apply --whitespace=nowarn --recount -C0 "$p" 2>/dev/null || echo "FAIL_APPLY $n"
      ;;
  esac
done
touch .osv-patches-applied
echo "APPLY VERIFY ZILSVC:$(grep -c 'RESULT ZILSVC' module/zfs/zil.c) ZILCOMMIT:$(grep -c 'RESULT ZILCOMMIT' module/zfs/zil.c) vqsvc:$(grep -c osv_svc_sum module/zfs/vdev_queue.c)"
echo "0032 proto order: $(grep -n arc_reduce_target_size_shrink_sync module/os/osv/zfs/zfs_initialize_osv.c | head -2 | tr '\n' ' ')"
echo APPLY_DONE
