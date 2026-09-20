#!/bin/bash
# Build the OSv PG18 image in the fedora:39 container.
# ARGS: <branch> <arch>   arch in {x86_64,aarch64}
set -x
BR="$1"; ARCH="${2:-x86_64}"
cd /work/osv || exit 1
exec > /work/build.log 2>&1

git remote get-url gh 2>/dev/null || git remote add gh https://github.com/gburd/osv-1.git
git fetch gh --tags
git checkout -B bench "gh/$BR" || exit 1
git submodule update --init --recursive apps modules/open_zfs/openzfs musl_1.2.1 external/$( [ "$ARCH" = aarch64 ] && echo aarch64 || echo x64 )/* 2>/dev/null
git submodule update --init --recursive 2>&1 | tail -5

# apps must be pinned to 3f93f43 (the seed_copy rofs-mode fix), NOT the 5cb1903 gitlink
# recorded in the osv tree. The gitlink predates the fix, so re-point apps explicitly.
git -C apps remote get-url gha 2>/dev/null || git -C apps remote add gha https://github.com/gburd/osv-apps.git
git -C apps fetch gha 2>&1 | tail -2
git -C apps checkout -B benchapps 3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3 || echo "FATAL: cannot pin apps to 3f93f43"

echo "=== IDENTITY ==="
echo "OSV_SHA=$(git rev-parse HEAD)"
echo "APPS_SHA=$(git -C apps rev-parse HEAD)"
echo "ZFS_SHA=$(git -C modules/open_zfs/openzfs rev-parse HEAD)"
echo "ZFS_META=$(grep -E '^Version' modules/open_zfs/openzfs/META 2>/dev/null)"

# TRAP: apps must be 3f93f43, and .PHONY must survive submodule ops
git -C apps rev-parse HEAD | grep -q '^3f93f43' || { echo "FATAL: apps pin wrong: $(git -C apps rev-parse HEAD)"; }
echo "SEEDCOPY_FIX_PRESENT=$(grep -c 'rofs' apps/postgres18-musl/seed_copy.c)"
PH=$(grep -c 'PHONY: module build' apps/postgres18-musl/Makefile)
echo "PHONY_COUNT=$PH"
if [ "$PH" != "1" ]; then
  echo "FIXING .PHONY"
  sed -i '1i .PHONY: module build' apps/postgres18-musl/Makefile
  grep -c 'PHONY: module build' apps/postgres18-musl/Makefile
fi

echo "=== base guards ==="
if [ "$ARCH" = aarch64 ]; then
  # psABI TCB canary defect is x86-only: 2-word TCB, GCC reads the __stack_chk_guard global.
  echo "aarch64_tcb_void_ptr_fields=$(grep -cE 'void \*' arch/aarch64/arch-tls.hh)  (expect 2)"
  echo "aarch64_mstack_protector_guard_hits=$(grep -r 'mstack-protector-guard' Makefile arch/aarch64/ conf/ 2>/dev/null | wc -l)  (expect 0)"
else
  echo "stack_guard=$(grep -c stack_guard arch/x64/arch-tls.hh)  (expect 3)"
fi
echo "OSV_FORK_RANGE_BS=$(grep -c OSV_FORK_RANGE_BS core/mmu.cc)  (expect 2)"
echo "OSV_FORK_LARGE_SHARE=$(grep -c OSV_FORK_LARGE_SHARE core/mmu.cc)  (expect 2)"

cat > /work/incontainer.sh <<'EOS'
set -x
cd /work/osv
# static libs FIRST in their own transaction (else Makefile:2028 libstdc++.a check fails)
dnf install -y gcc gcc-c++ libstdc++-static glibc-static
dnf install -y --skip-broken flex bison git make cmake python3 python3-pip python3-setuptools perl perl-FindBin \
  openssl-devel libedit-devel boost-devel genromfs autoconf automake libtool \
  ncurses-devel bzip2 patch wget curl qemu-img qemu-system-x86 qemu-system-aarch64 \
  musl-gcc musl-libc-static musl-devel gnutls-devel libaio-devel elfutils-libelf-devel \
  zlib-devel libuuid-devel libblkid-devel openssl libtirpc-devel lz4-devel libzstd-devel \
  file which findutils tar gzip xz binutils bc unzip
# distro is REQUIRED by scripts/download_aarch64_packages.py (it imports it at line 4);
# without it the script dies at import and the boost sysroot is never fetched, and
# Makefile:2105 then hard-stops. --quiet||true hid this last run; do NOT silence it.
pip3 install requests distro 2>&1 | tail -2
python3 -c 'import distro; print("DISTRO_OK", distro.id())'
which musl-gcc; musl-gcc --version | head -1
EOS

CTRARCH_IMG=fedora:39
docker pull $CTRARCH_IMG
docker rm -f bld 2>/dev/null
docker run -d --name bld --privileged --network host -v /work:/work -v /mnt/nv:/mnt/nv $CTRARCH_IMG sleep infinity
docker exec bld bash /work/incontainer.sh || { echo "FATAL: container deps"; exit 1; }

NPROC=$(nproc)
ARCHARG=""
[ "$ARCH" = aarch64 ] && ARCHARG="arch=aarch64"

# aarch64 needs the prebuilt boost/gcc sysroot (Makefile:2105 hard-errors without it)
if [ "$ARCH" = aarch64 ]; then
  docker exec bld bash -lc "cd /work/osv && ./scripts/download_aarch64_packages.py" 2>&1 | tail -15
  echo "AARCH64_PKGS_RC=$?"
  ls -d build/downloaded_packages/aarch64/boost/install 2>&1
fi

# fs=rofs: create_rofs_disk() builds the image host-side via gen-rofs-img.py, no guest boot, no cpiod.
# --use-openzfs only gates create_zfs_disk/create_zfs_filesystem (fs=zfs), so it is inert for rofs;
# passed anyway to be explicit. conf_zfs=openzfs is what selects the OpenZFS kernel objects.
#
# TRAP (found here): Makefile:2242 only adds libsolaris.so/zpool.so/zfs.so to bootfs_dep when fs=zfs.
# Under fs=rofs they are never built, but the zfs module's manifest still lists them, so
# gen-rofs-img.py dies with FileNotFoundError: 'libsolaris.so'. Build the ZFS .so set FIRST.
ZFSSOS="libsolaris.so zpool.so zfs.so libzfs.so libuutil.so libzfs_core.so libzutil.so libshare.so libtpool.so"
OUTDIR=build/release$( [ "$ARCH" = aarch64 ] && echo .aarch64 || echo .x64 )
TGTS=""; for s in $ZFSSOS; do TGTS="$TGTS $OUTDIR/$s"; done
docker exec bld bash -lc "cd /work/osv && make -j$NPROC $ARCHARG conf_fork=1 conf_zfs=openzfs fs=rofs $TGTS" 2>&1 | tail -25
echo "ZFS_SO_PREBUILD_RC=$?"
ls -l $OUTDIR/libsolaris.so $OUTDIR/zpool.so $OUTDIR/zfs.so 2>&1 | head

docker exec bld bash -lc "cd /work/osv && ./scripts/build -j$NPROC $ARCHARG conf_fork=1 conf_zfs=openzfs fs=rofs --use-openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl" 2>&1 | tail -100
echo "BUILD_RC_UNRELIABLE=$?  (scripts/build exits 0 on module failure - check artifacts)"
grep -icE 'error|failed' /work/osv/build.out 2>/dev/null

echo "=== ARTIFACTS ==="
ls -la build/last/ 2>/dev/null | head -30
for f in build/last/usr.img build/last/loader.elf build/last/loader.img; do
  [ -f "$f" ] && echo "SIZE $f $(stat -c %s $f) ($(du -h $f|cut -f1))"
done
echo "=== IMAGE SIZE CHECK (expect ~119MB rofs; ~8MB = PG-FREE FAILURE) ==="
du -m build/last/usr.img 2>/dev/null
echo "=== manifest entries ==="
wc -l build/last/*.manifest 2>/dev/null
echo "=== is postgres in the image? ==="
grep -c postgres build/last/usr.manifest 2>/dev/null
grep postgres build/last/usr.manifest 2>/dev/null | head -5
ls -la apps/postgres18-musl/install/bin/postgres 2>/dev/null || echo "NO PG BINARY BUILT"
apps/postgres18-musl/install/bin/postgres --version 2>/dev/null || true
echo "=== OpenZFS build-time proof ==="
echo "open_zfs objects: $(find build -path '*open_zfs*' -name '*.o' 2>/dev/null|wc -l)"
echo "bsd zfs spa objects (expect 0): $(find build -path '*bsd*fs/zfs*' -name 'spa*.o' 2>/dev/null | wc -l)"
echo "bsd zfs objects total (expect 0): $(find build -path '*bsd*fs/zfs*' -name '*.o' 2>/dev/null | wc -l)"
for l in libzfs_core libzutil libshare libtpool; do
  echo -n "$l: "; find build/last -name "*$l*" 2>/dev/null | head -2 | tr '\n' ' '; grep -c "$l" build/last/usr.manifest 2>/dev/null
done
echo BUILD_DONE
