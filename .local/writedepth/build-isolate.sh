#!/bin/bash
# Build OSv zfs_builder.elf + zfs-bench.so on the metal (Debian) inside a
# fedora:39 container.  BOOTING is native qemu 7.2 -M pc (run scripts).
# Branch bench/writedepth = flushinline probes + 0041 ZILSVC discriminator.
set -x
BR="${1:-bench/writedepth}"
cd /work/osv || exit 1
exec > /work/build.log 2>&1

git remote get-url gh 2>/dev/null || git remote add gh https://github.com/gburd/osv-1.git
git fetch gh --tags 2>&1 | tail -2
git checkout -B bench "gh/$BR" || exit 1
git submodule update --init --recursive apps modules/open_zfs/openzfs musl_1.2.1 external/x64/* 2>/dev/null
git submodule update --init --recursive 2>&1 | tail -3

echo "=== IDENTITY ==="
echo "OSV_SHA=$(git rev-parse HEAD)"
echo "APPS_SHA=$(git -C apps rev-parse HEAD 2>/dev/null)"
echo "ZFS_SHA=$(git -C modules/open_zfs/openzfs rev-parse HEAD)"

# .PHONY guard for the PG app (survives submodule ops)
PH=$(grep -c 'PHONY: module build' apps/postgres18-musl/Makefile 2>/dev/null || echo 0)
if [ "$PH" != "1" ]; then sed -i '1i .PHONY: module build' apps/postgres18-musl/Makefile 2>/dev/null; fi

# force a clean patch re-apply (drop stamp so the Makefile re-applies the series)
rm -f modules/open_zfs/openzfs/.osv-patches-applied
git -C modules/open_zfs/openzfs checkout -q -- . 2>/dev/null
git -C modules/open_zfs/openzfs clean -qfd 2>/dev/null

cat > /work/incontainer-deps.sh <<'EOS'
set -x
cd /work/osv
dnf install -y gcc gcc-c++ libstdc++-static glibc-static
dnf install -y --skip-broken flex bison git make cmake python3 python3-pip python3-setuptools perl perl-FindBin \
  openssl-devel libedit-devel boost-devel genromfs autoconf automake libtool \
  ncurses-devel bzip2 patch wget curl qemu-img \
  musl-gcc musl-libc-static musl-devel gnutls-devel libaio-devel elfutils-libelf-devel \
  zlib-devel libuuid-devel libblkid-devel openssl libtirpc-devel lz4-devel libzstd-devel \
  file which findutils tar gzip xz binutils bc unzip
which musl-gcc; musl-gcc --version | head -1
EOS

docker pull fedora:39
docker rm -f bld 2>/dev/null
docker run -d --name bld --privileged --network host -v /work:/work fedora:39 sleep infinity
docker exec bld bash /work/incontainer-deps.sh || { echo "FATAL: container deps"; exit 1; }

NPROC=$(nproc)

echo "=== PATCH VERIFY (0041 present in series) ==="
ls modules/open_zfs/patches/0041-zfs-step1-write-service-vs-depth-discriminator.patch

# Phase 1: ZFS .so set + zfs_builder.elf (isolate needs these).
ZFSSOS="libsolaris.so zpool.so zfs.so libzfs.so libuutil.so libzfs_core.so libzutil.so libshare.so libtpool.so"
OUTDIR=build/release.x64
TGTS=""; for s in $ZFSSOS; do TGTS="$TGTS $OUTDIR/$s"; done
docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs $TGTS" 2>&1 | tail -20
echo "ZFS_SO_RC=$?"

# VERIFY the 0041 probe actually landed in the patched submodule source.
echo "=== PATCH APPLIED VERIFY (grep built source) ==="
echo "ZILSVC dump:   $(grep -c 'RESULT ZILSVC' modules/open_zfs/openzfs/module/zfs/zil.c)"
echo "vq svc hook:   $(grep -c 'osv_svc_sum' modules/open_zfs/openzfs/module/zfs/vdev_queue.c)"
echo "vq depth hook: $(grep -c 'osv_swd_accum' modules/open_zfs/openzfs/module/zfs/vdev_queue.c)"
echo "ZILDEPTH:      $(grep -c 'RESULT ZILDEPTH' modules/open_zfs/openzfs/module/zfs/zil.c)"
echo "ZILISSUER:     $(grep -c 'RESULT ZILISSUER' modules/open_zfs/openzfs/module/zfs/zil.c)"
echo "ZILFLUSHLAT:   $(grep -c 'RESULT ZILFLUSHLAT' modules/open_zfs/openzfs/module/zfs/zil.c)"
grep -n "OZFS-PATCH-SKIPPED\|OZFS-PATCH-SERIES-INCOMPLETE\|patch does not apply\|corrupt patch" /work/build.log | tail -10

# Build zfs_builder.elf + the zfs-bench.so isolate harness.
docker exec bld bash -lc "cd /work/osv && bash scripts/bench/rebuild-bench.sh openzfs" 2>&1 | tail -25
echo "BENCH_RC=$?"
ls -l $OUTDIR/zfs_builder.elf $OUTDIR/zfs-bench.so 2>&1
echo "=== ISOLATE BUILD DONE ==="
