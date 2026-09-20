#!/bin/bash
# Build the full PG18 rofs image (STEP C HammerDB SUT). Runs in the fedora bld
# container that build-isolate.sh already created. Booted natively later.
set -x
cd /work/osv || exit 1
exec > /work/build-pg.log 2>&1
NPROC=$(nproc)

# aarch64 not needed. x86 rofs PG image.
# ZFS .so set must exist first (build-isolate already built them under fs=rofs).
docker exec bld bash -lc "cd /work/osv && ./scripts/build -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs --use-openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl" 2>&1 | tail -60
echo "BUILD_RC_UNRELIABLE=$?  (scripts/build exits 0 on module failure -- check artifacts)"

echo "=== ARTIFACTS ==="
ls -la build/last/ 2>/dev/null | head -20
for f in build/last/usr.img build/last/loader.elf; do
  [ -f "$f" ] && echo "SIZE $f $(stat -c %s $f)"
done
echo "=== IMAGE SIZE (expect ~119MB rofs; ~8MB = PG-FREE FAILURE) ==="
du -m build/last/usr.img 2>/dev/null
echo "=== is postgres in the image? ==="
grep -c postgres build/last/usr.manifest 2>/dev/null
apps/postgres18-musl/install/bin/postgres --version 2>/dev/null || echo "NO PG BINARY"
echo "=== OpenZFS objects (expect >0) / bsd zfs (expect 0) ==="
echo "open_zfs objects: $(find build -path '*open_zfs*' -name '*.o' 2>/dev/null|wc -l)"
echo "bsd zfs objects: $(find build -path '*bsd*fs/zfs*' -name '*.o' 2>/dev/null | wc -l)"
echo "=== inline-flush patch still in source? ==="
grep -c "zio_flush_inline_enabled" modules/open_zfs/openzfs/module/zfs/zio.c
echo PG_BUILD_DONE
