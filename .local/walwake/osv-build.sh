#!/bin/bash
# Build a MINIMAL OSv OpenZFS image for the walwake syncwrite-mt isolate:
# zfs_builder.elf + zfs-bench.so + zpool.so/zfs.so/libsolaris.so. NO postgres.
# Builds inside fedora:39 (qemu 8.1.3 can boot OSv under -M pc). Branch:
# bench/walwake-mt on gh-fork/osv-1 (a2a-shape-fix all levers + syncwrite-mt).
set -x
exec > /home/ec2-user/osv-build.log 2>&1
echo "=== START $(date) ==="

cd /home/ec2-user
if [ ! -d osv ]; then
  git clone https://github.com/gburd/osv-1.git osv 2>&1 | tail -3
fi
cd /home/ec2-user/osv
git fetch origin 2>&1 | tail -2
git checkout -B bench origin/bench/walwake-mt 2>&1 | tail -3
echo "OSV_HEAD=$(git rev-parse HEAD)"
echo "SYNCWRITE_MT_PRESENT=$(grep -c wl_syncwrite_mt scripts/bench/zfs-bench.c)"
echo "ZIL_HIRES_PRESENT=$(grep -c openzfs_cv_timedwait_hires bsd/porting/netport1.cc)"

git submodule update --init kbuild musl_0.9.12 2>&1 | tail -3
git submodule update --init --recursive modules/open_zfs/openzfs musl_1.2.1 2>&1 | tail -5
git submodule update --init --recursive external/x64/* 2>&1 | tail -5
echo "ZFS_SHA=$(git -C modules/open_zfs/openzfs rev-parse HEAD 2>&1)"

cat > /home/ec2-user/incontainer-deps.sh <<'EOS'
set -x
cd /work/osv
dnf install -y gcc gcc-c++ libstdc++-static glibc-static
dnf install -y --skip-broken flex bison git make cmake python3 python3-pip python3-setuptools perl perl-FindBin \
  openssl-devel libedit-devel boost-devel genromfs autoconf automake libtool \
  ncurses-devel bzip2 patch wget curl qemu-img qemu-system-x86 \
  musl-gcc musl-libc-static musl-devel gnutls-devel libaio-devel elfutils-libelf-devel \
  zlib-devel libuuid-devel libblkid-devel openssl libtirpc-devel lz4-devel libzstd-devel \
  file which findutils tar gzip xz binutils bc unzip
pip3 install requests distro 2>&1 | tail -2
which musl-gcc; musl-gcc --version | head -1
EOS

sudo docker pull fedora:39 2>&1 | tail -3
sudo docker rm -f bld 2>/dev/null
sudo docker run -d --name bld --privileged --network host \
  -v /home/ec2-user:/work fedora:39 sleep infinity
sudo docker exec bld bash /work/incontainer-deps.sh 2>&1 | tail -20 || { echo "FATAL: container deps"; exit 1; }

NPROC=$(nproc)
OUTDIR=build/release.x64

ZFSSOS="libsolaris.so zpool.so zfs.so libzfs.so libuutil.so libzfs_core.so libzutil.so libshare.so libtpool.so"
TGTS=""; for s in $ZFSSOS; do TGTS="$TGTS $OUTDIR/$s"; done
sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs OSV_NO_JAVA_TESTS=1 $TGTS" 2>&1 | tail -25
echo "ZFS_SO_RC=${PIPESTATUS[0]}"
ls -l $OUTDIR/libsolaris.so $OUTDIR/zpool.so $OUTDIR/zfs.so 2>&1 | head

sudo docker exec bld bash -lc "cd /work/osv && bash scripts/bench/rebuild-bench.sh openzfs" 2>&1 | tail -25
echo "BENCH_RC=${PIPESTATUS[0]}"

echo "=== ARTIFACTS ==="
ls -l $OUTDIR/zfs_builder.elf $OUTDIR/zfs-bench.so $OUTDIR/zpool.so $OUTDIR/zfs.so 2>&1
echo "=== bench .so symbol gate (must be empty) ==="
sudo docker exec bld bash -lc "nm -D /work/osv/$OUTDIR/zfs-bench.so | grep -E 'GLIBCXX|CXXABI|__isoc23'" 2>&1 || echo "GATE_OK_no_bad_symbols"
echo "=== END $(date) ==="
echo OSV_BUILD_DONE
