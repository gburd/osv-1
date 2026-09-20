#!/bin/bash
# Build the MINIMAL OSv OpenZFS image for the syncwrite-mt isolate:
# zfs_builder.elf + zfs-bench.so + zpool.so/zfs.so/libsolaris.so. NO postgres.
# Branch: bank/sched-adaptive-idle-spin on gh-fork (osv-1.git).
set -x
exec > /scratch/osv-build.log 2>&1
echo "=== BUILD START $(date) ==="

cd /scratch
if [ ! -d osv ]; then
  git clone https://github.com/gburd/osv-1.git osv 2>&1 | tail -3
fi
cd /scratch/osv
git remote get-url gh 2>/dev/null || git remote add gh https://github.com/gburd/osv-1.git
git fetch gh 2>&1 | tail -2
git checkout -B adaptive gh/bank/sched-adaptive-idle-spin 2>&1 | tail -3
echo "OSV_HEAD=$(git rev-parse HEAD)"
echo "ADAPTIVE_PRESENT=$(grep -c idle_spin_window core/sched.cc) (expect >=4)"
echo "IDLE_SPIN_MAX=$(grep -c idle_spin_max core/sched.cc) (expect 5)"
echo "SYNCWRITE_MT=$(grep -c wl_syncwrite_mt scripts/bench/zfs-bench.c) (expect >=1)"
echo "WAKE_PULL_TRUE=$(grep -c 'wake_pull_enabled = true' core/sched.cc) (expect 1)"

git submodule update --init kbuild musl_0.9.12 2>&1 | tail -2
git submodule update --init --recursive modules/open_zfs/openzfs musl_1.2.1 2>&1 | tail -3
git submodule update --init --recursive external/x64/* 2>&1 | tail -3
echo "ZFS_SHA=$(git -C modules/open_zfs/openzfs rev-parse HEAD 2>&1)"

cat > /scratch/incontainer-deps.sh <<'EOS'
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

docker pull fedora:39 2>&1 | tail -2
docker rm -f bld 2>/dev/null
docker run -d --name bld --privileged --network host -v /scratch:/work fedora:39 sleep infinity
docker exec bld bash /work/incontainer-deps.sh 2>&1 | tail -12 || { echo "FATAL: container deps"; exit 1; }

NPROC=$(nproc)
OUTDIR=build/release.x64
ZFSSOS="libsolaris.so zpool.so zfs.so libzfs.so libuutil.so libzfs_core.so libzutil.so libshare.so libtpool.so"
TGTS=""; for s in $ZFSSOS; do TGTS="$TGTS $OUTDIR/$s"; done
docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs OSV_NO_JAVA_TESTS=1 $TGTS" 2>&1 | tail -15
echo "ZFS_SO_RC=${PIPESTATUS[0]}"
ls -l $OUTDIR/zpool.so $OUTDIR/zfs.so 2>&1 | head

docker exec bld bash -lc "cd /work/osv && bash scripts/bench/rebuild-bench.sh openzfs" 2>&1 | tail -20
echo "BENCH_RC=${PIPESTATUS[0]}"

echo "=== ARTIFACTS ==="
ls -l $OUTDIR/zfs_builder.elf $OUTDIR/zfs-bench.so 2>&1
echo "=== END $(date) ==="
echo OSV_BUILD_DONE
