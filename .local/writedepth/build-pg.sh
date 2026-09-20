#!/bin/bash
# Build the full PG18 rofs image (HammerDB SUT) in the fedora bld container.
# Patches already applied+stamped by apply-series.sh; submodule at pin 6330a45b.
set -x
cd /work/osv || exit 1
exec > /work/build-pg.log 2>&1
NPROC=$(nproc)
sudo chown -R admin:admin /work/osv/build 2>/dev/null
sudo docker exec bld bash -lc "cd /work/osv && ./scripts/build -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs --use-openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl" 2>&1 | tail -50
echo "BUILD_RC_UNRELIABLE=$?"
echo "=== ARTIFACTS ==="
ls -la build/last/ 2>/dev/null | head
for f in build/last/usr.img build/last/loader.elf; do [ -f "$f" ] && echo "SIZE $f $(stat -c %s $f)"; done
echo "=== IMAGE SIZE (expect ~100+MB; ~8MB = PG-FREE FAILURE) ==="
du -m build/last/usr.img 2>/dev/null
echo "postgres in manifest: $(grep -c postgres build/last/usr.manifest 2>/dev/null)"
echo "=== ZILWAKE2/ZILSVC/OSV_IDLE_SPIN in loader.elf? ==="
echo "IDLE_SPIN:$(strings build/last/loader.elf 2>/dev/null | grep -c OSV_IDLE_SPIN) ZILSVC:$(strings build/last/loader.elf 2>/dev/null | grep -c 'RESULT ZILSVC')"
echo PG_BUILD_DONE
