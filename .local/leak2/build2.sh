#!/bin/bash
# Incremental full image rebuild (container 'bld' already up + deps installed).
set -x
cd /work/osv || exit 1
exec > /work/build2.log 2>&1
echo "OSV_SHA=$(git rev-parse HEAD)"
echo "APPS_SHA=$(git -C apps rev-parse HEAD)"
echo "HIST_MEMPOOL=$(grep -c fbhist core/mempool.cc)"
echo "HIST_MMU=$(grep -c fbhist_on_reap core/mmu.cc)"
echo "HIST_PROBE=$(grep -c fbhist_dump core/leak_probe.cc)"

NPROC=$(nproc)
sg docker -c "docker exec bld bash -lc 'cd /work/osv && ./scripts/build -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs --use-openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl'" 2>&1 | tail -40
echo "=== ARTIFACTS ==="
ls -la build/last/ 2>/dev/null | head
for f in build/last/usr.img build/last/loader.elf; do
  [ -f "$f" ] && echo "SIZE $f $(stat -c %s $f)"
done
echo "=== image size (expect ~119MB rofs; ~8MB = PG-FREE FAILURE) ==="
du -m build/last/usr.img 2>/dev/null
echo "=== postgres in image? ==="
grep -c postgres build/last/usr.manifest 2>/dev/null
echo "=== histogram symbols in built loader? ==="
strings build/last/loader.elf 2>/dev/null | grep -c 'FBHIST\|fb_live'
echo BUILD2_DONE
