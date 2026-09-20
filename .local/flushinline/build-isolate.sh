#!/bin/bash
# Build on the metal (Debian host) inside a fedora:39 container.
# Produces: (1) zfs_builder.elf + zfs-bench.so  (STEP B isolate)
#           (2) full PG18 rofs image            (STEP C HammerDB) -- second phase
# BOOTING is done natively (qemu 7.2 -M pc) by the run scripts, NOT in the container.
set -x
BR="${1:-bench/flushinline}"
cd /work/osv || exit 1
exec > /work/build.log 2>&1

git remote get-url gh 2>/dev/null || git remote add gh https://github.com/gburd/osv-1.git
git fetch gh --tags 2>&1 | tail -2
git checkout -B bench "gh/$BR" || exit 1
git submodule update --init --recursive apps modules/open_zfs/openzfs musl_1.2.1 external/x64/* 2>/dev/null
git submodule update --init --recursive 2>&1 | tail -3

echo "=== IDENTITY ==="
echo "OSV_SHA=$(git rev-parse HEAD)"
echo "APPS_SHA=$(git -C apps rev-parse HEAD)"
echo "ZFS_SHA=$(git -C modules/open_zfs/openzfs rev-parse HEAD)"

# .PHONY guard for the PG app (survives submodule ops)
PH=$(grep -c 'PHONY: module build' apps/postgres18-musl/Makefile 2>/dev/null || echo 0)
if [ "$PH" != "1" ]; then sed -i '1i .PHONY: module build' apps/postgres18-musl/Makefile; fi

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

# --- VERIFY THE INLINE-FLUSH PATCH IS PRESENT IN THE BUILT SOURCE ---
echo "=== PATCH VERIFY (before build applies patches) ==="
ls modules/open_zfs/patches/0040-zfs-inline-flush-completion-OSV_ZIL_FLUSH_INLINE.patch

# Phase 1: build the ZFS .so set + zfs_builder.elf (isolate needs these).
ZFSSOS="libsolaris.so zpool.so zfs.so libzfs.so libuutil.so libzfs_core.so libzutil.so libshare.so libtpool.so"
OUTDIR=build/release.x64
TGTS=""; for s in $ZFSSOS; do TGTS="$TGTS $OUTDIR/$s"; done
docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs $TGTS" 2>&1 | tail -15
echo "ZFS_SO_RC=$?"

# VERIFY the patch actually landed in the patched submodule source now that
# the Makefile applied the series.
echo "=== PATCH APPLIED VERIFY (grep built source) ==="
grep -c "zio_flush_inline_enabled\|OSV_ZIL_FLUSH_INLINE" modules/open_zfs/openzfs/module/zfs/zio.c
grep -n "OZFS-PATCH-SKIPPED\|OZFS-PATCH-SERIES-INCOMPLETE" /work/build.log | tail -5

# Build zfs_builder.elf + the zfs-bench.so isolate harness.
docker exec bld bash -lc "cd /work/osv && bash scripts/bench/rebuild-bench.sh openzfs" 2>&1 | tail -20
echo "BENCH_RC=$?"
ls -l $OUTDIR/zfs_builder.elf $OUTDIR/zfs-bench.so 2>&1


echo "=== ISOLATE BUILD DONE ==="
