#!/bin/bash
# Test all three paths of the OpenZFS patch-apply chain on a real checked-out
# tree. The point is to prove the FAILURE path actually fails, because the
# previous version could not fail at all: skip notice to stderr only, $skipped
# never acted on, `ok` never set to 0 so the INCOMPLETE branch was dead code,
# and the stamp touched unconditionally BEFORE the check (which also made the
# omission permanent, since the stamp is what makes this idempotent).
#
# Copyright (C) 2026 Greg Burd
set -u
T=$1   # a checked-out osv tree with the openzfs submodule present
cd "$T" || exit 1
STAMP=modules/open_zfs/openzfs/.osv-patches-applied
FAILED=modules/open_zfs/openzfs/.osv-patches-failed

reset() {
  git -C modules/open_zfs/openzfs checkout -q . 2>/dev/null
  git -C modules/open_zfs/openzfs clean -qfd 2>/dev/null
  rm -f "$STAMP" "$FAILED"
}

echo "=== TEST 1: all patches apply => stamp created, no failure file, build proceeds"
reset
OUT=$(make -n conf_fork=1 conf_zfs=openzfs fs=ramfs 2>&1)
echo "  OZFS lines: $(printf '%s' "$OUT" | grep -c OZFS)"
printf '%s\n' "$OUT" | grep -E 'OZFS-PATCH-(SKIPPED|RECOUNTED)|SERIES-INCOMPLETE' | head -5
echo "  stamp present: $([ -f $STAMP ] && echo YES || echo NO)   (want YES)"
echo "  failed file:   $([ -f $FAILED ] && echo YES || echo NO)  (want NO)"
echo "  make error:    $(printf '%s' "$OUT" | grep -c 'INCOMPLETE -- these patches did not apply')  (want 0)"

echo
echo "=== TEST 2: inject a patch that CANNOT apply => build must FAIL and say so"
reset
cat > modules/open_zfs/patches/9999-deliberately-broken.patch <<'EOF'
--- a/module/os/osv/zfs/vdev_disk.c
+++ b/module/os/osv/zfs/vdev_disk.c
@@ -1,3 +1,4 @@
 this context does not exist anywhere in the file
 nor does this
+added line
EOF
OUT=$(make -n conf_fork=1 conf_zfs=openzfs fs=ramfs 2>&1)
printf '%s\n' "$OUT" | grep -E 'OZFS-PATCH-SKIPPED|SERIES-INCOMPLETE|did not apply' | head -4
echo "  stamp present: $([ -f $STAMP ] && echo YES || echo NO)   (want NO: must not mark applied)"
echo "  failed file:   $([ -f $FAILED ] && echo YES || echo NO)  (want YES)"
echo "  build aborted: $(printf '%s' "$OUT" | grep -c 'did not apply')  (want >=1)"
echo "  contents of failed file: $(cat $FAILED 2>/dev/null)"

echo
echo "=== TEST 3: the failure is STICKY until cleared (no silent recovery)"
OUT=$(make -n conf_fork=1 conf_zfs=openzfs fs=ramfs 2>&1)
echo "  still aborts: $(printf '%s' "$OUT" | grep -c 'did not apply')  (want >=1)"
rm -f modules/open_zfs/patches/9999-deliberately-broken.patch
rm -f "$FAILED"
reset
OUT=$(make -n conf_fork=1 conf_zfs=openzfs fs=ramfs 2>&1)
echo "  after fix+clear, aborts: $(printf '%s' "$OUT" | grep -c 'did not apply')  (want 0)"
echo "  stamp present: $([ -f $STAMP ] && echo YES || echo NO)   (want YES)"

echo
echo "=== TEST 4: a --recount rescue is REPORTED (was previously silent)"
reset
python3 - <<'PY'
import re
p='modules/open_zfs/patches/0044-zfs-vdev-nonrot.patch'
s=open(p).read()
s=s.replace('@@ -103,6 +103,37 @@','@@ -103,6 +103,32 @@')  # re-break the count
open(p,'w').write(s)
print("  re-broke 0044 hunk count 37 -> 32")
PY
OUT=$(make -n conf_fork=1 conf_zfs=openzfs fs=ramfs 2>&1)
printf '%s\n' "$OUT" | grep -E 'RECOUNTED' | head -3
echo "  recount reported: $(printf '%s' "$OUT" | grep -c RECOUNTED)  (want >=1)"
echo "  stamp present: $([ -f $STAMP ] && echo YES || echo NO)   (want YES: recount still applies)"
git checkout -q modules/open_zfs/patches/0044-zfs-vdev-nonrot.patch
reset
echo "PATCHCHAIN_TESTS_DONE"
