#!/bin/bash
# Build the instrumented OSv PG18 image in the fedora:39 container.
# Tree is ALREADY checked out (bench/leakhunt + apps 3f93f43) and instrumented.
set -x
cd /work/osv || exit 1
exec > /work/build.log 2>&1

echo "=== IDENTITY ==="
echo "OSV_SHA=$(git rev-parse HEAD)"
echo "APPS_SHA=$(git -C apps rev-parse HEAD)"
echo "ZFS_SHA=$(git -C modules/open_zfs/openzfs rev-parse HEAD 2>/dev/null)"
echo "INSTRUMENTED=$(grep -c g_app_fallback_bytes core/mempool.cc)"
echo "PROBE_FB=$(grep -c app_fallback core/leak_probe.cc)"

# .PHONY guard (survives submodule ops)
PH=$(grep -c 'PHONY: module build' apps/postgres18-musl/Makefile)
echo "PHONY_COUNT=$PH"
if [ "$PH" != "1" ]; then
  sed -i '1i .PHONY: module build' apps/postgres18-musl/Makefile
fi

cat > /work/incontainer.sh <<'EOS'
set -x
cd /work/osv
git config --global --add safe.directory '*'
dnf install -y gcc gcc-c++ libstdc++-static glibc-static
dnf install -y --skip-broken flex bison git make cmake python3 python3-pip python3-setuptools perl perl-FindBin \
  openssl-devel libedit-devel boost-devel genromfs autoconf automake libtool \
  ncurses-devel bzip2 patch wget curl qemu-img qemu-system-x86 \
  musl-gcc musl-libc-static musl-devel gnutls-devel libaio-devel elfutils-libelf-devel \
  zlib-devel libuuid-devel libblkid-devel openssl libtirpc-devel lz4-devel libzstd-devel \
  file which findutils tar gzip xz binutils bc unzip
pip3 install --quiet requests 2>/dev/null || true
which musl-gcc; musl-gcc --version | head -1
EOS

docker pull fedora:39
docker rm -f bld 2>/dev/null
docker run -d --name bld --privileged --network host -v /work:/work -v /mnt/nv:/mnt/nv fedora:39 sleep infinity
docker exec bld bash /work/incontainer.sh || { echo "FATAL: container deps"; exit 1; }

NPROC=$(nproc)
# Pre-build the ZFS .so set (rofs manifest lists them; gen-rofs-img.py needs them present)
ZFSSOS="libsolaris.so zpool.so zfs.so libzfs.so libuutil.so libzfs_core.so libzutil.so libshare.so libtpool.so"
OUTDIR=build/release.x64
TGTS=""; for s in $ZFSSOS; do TGTS="$TGTS $OUTDIR/$s"; done
docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs $TGTS" 2>&1 | tail -20
echo "ZFS_SO_PREBUILD_RC=$?"
ls -l $OUTDIR/libsolaris.so $OUTDIR/zpool.so $OUTDIR/zfs.so 2>&1 | head

docker exec bld bash -lc "cd /work/osv && ./scripts/build -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs --use-openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl" 2>&1 | tail -60
echo "BUILD_RC_UNRELIABLE=$? (scripts/build exits 0 on module failure - check artifacts)"

echo "=== ARTIFACTS ==="
ls -la build/last/ 2>/dev/null | head -20
for f in build/last/usr.img build/last/loader.elf; do
  [ -f "$f" ] && echo "SIZE $f $(stat -c %s $f)"
done
echo "=== image size (expect ~119MB rofs; ~8MB = PG-FREE FAILURE) ==="
du -m build/last/usr.img 2>/dev/null
echo "=== is postgres in the image? ==="
grep -c postgres build/last/usr.manifest 2>/dev/null
apps/postgres18-musl/install/bin/postgres --version 2>/dev/null || echo "NO PG BINARY"
echo "=== instrument in built loader? ==="
strings build/last/loader.elf 2>/dev/null | grep -c 'fb_bytes' || echo "0"
echo BUILD_DONE
