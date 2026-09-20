#!/bin/bash
# Build the OSv PG18 image on the metal host in a fedora:39 container.
# Base = gh-fork/bank/fork-arena-real-reclaim (VERIFIED base, gate PASS).
# apps re-pinned to 3f93f43 (seed_copy rofs-mode fix).
set -x
BR="${1:-bank/fork-arena-real-reclaim}"
cd /work/osv || exit 1
exec > /work/build.log 2>&1

git remote get-url gh 2>/dev/null || git remote add gh https://github.com/gburd/osv-1.git
git fetch gh --tags 2>&1 | tail -3
git checkout -B bench "gh/$BR" || exit 1
git submodule update --init --recursive apps modules/open_zfs/openzfs musl_1.2.1 external/x64/* 2>/dev/null
git submodule update --init --recursive 2>&1 | tail -5

# apps must be pinned to 3f93f43 (the seed_copy rofs-mode fix), NOT the recorded gitlink.
git -C apps remote get-url gha 2>/dev/null || git -C apps remote add gha https://github.com/gburd/osv-apps.git
git -C apps fetch gha 2>&1 | tail -2
git -C apps checkout -B benchapps 3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3 || echo "FATAL: cannot pin apps to 3f93f43"

echo "=== IDENTITY ==="
echo "OSV_SHA=$(git rev-parse HEAD)"
echo "APPS_SHA=$(git -C apps rev-parse HEAD)"
echo "ZFS_SHA=$(git -C modules/open_zfs/openzfs rev-parse HEAD)"
echo "ZFS_META=$(grep -E '^Version' modules/open_zfs/openzfs/META 2>/dev/null)"

git -C apps rev-parse HEAD | grep -q '^3f93f43' || echo "FATAL: apps pin wrong: $(git -C apps rev-parse HEAD)"
echo "SEEDCOPY_MKDIR_FIX=$(grep -c 'mkdir(dst, 0700)' apps/postgres18-musl/seed_copy.c)  (expect 1)"
PH=$(grep -c 'PHONY: module build' apps/postgres18-musl/Makefile)
echo "PHONY_COUNT=$PH"
if [ "$PH" != "1" ]; then
  sed -i '1i .PHONY: module build' apps/postgres18-musl/Makefile
fi

echo "=== base gate markers (must all be present) ==="
echo "stack_guard=$(grep -c stack_guard arch/x64/arch-tls.hh)  (expect 3)"
echo "openzfs_cv_timedwait_hires=$(grep -c openzfs_cv_timedwait_hires bsd/porting/netport1.cc)  (expect 1)"
echo "wake_pull_enabled=$(grep -c 'wake_pull_enabled = true' core/sched.cc)  (expect 1)"
echo "write_cache.empty=$(grep -c 'write_cache.empty' core/pagecache.cc)  (expect 1)"
echo "vfs_dentry_hash_lock_held=$(grep -c vfs_dentry_hash_lock_held fs/vfs/vfs_dentry.cc)  (expect 2)"
echo "req_done_q=$(grep -c req_done_q drivers/virtio-blk.cc)  (expect 3)"
echo "OSV_FORK_RANGE_BS=$(grep -c OSV_FORK_RANGE_BS core/mmu.cc)  (expect 2)"
echo "OSV_FORK_LARGE_SHARE=$(grep -c OSV_FORK_LARGE_SHARE core/mmu.cc)  (expect 2)"
echo "=== adaptive-idle-spin fix markers (the code under test) ==="
echo "idle_spin_max=$(grep -c 'idle_spin_max' core/sched.cc)  (expect >=2)"
echo "OSV_IDLE_SPIN_ADAPTIVE=$(grep -c 'OSV_IDLE_SPIN_ADAPTIVE' core/sched.cc)  (expect 1, the A/B knob)"
echo "idle_spin_window_hh=$(grep -c 'idle_spin_window' include/osv/sched.hh)  (expect 1)"

cat > /work/incontainer.sh <<'EOS'
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
python3 -c 'import distro; print("DISTRO_OK", distro.id())'
which musl-gcc; musl-gcc --version | head -1
EOS

docker pull fedora:39
docker rm -f bld 2>/dev/null
docker run -d --name bld --privileged --network host -v /work:/work fedora:39 sleep infinity
docker exec bld bash /work/incontainer.sh || { echo "FATAL: container deps"; exit 1; }

NPROC=$(nproc)
OUTDIR=build/release.x64
# ZFS .so set first (rofs build does not add them to bootfs_dep -> gen-rofs-img.py FileNotFoundError)
ZFSSOS="libsolaris.so zpool.so zfs.so libzfs.so libuutil.so libzfs_core.so libzutil.so libshare.so libtpool.so"
TGTS=""; for s in $ZFSSOS; do TGTS="$TGTS $OUTDIR/$s"; done
docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs $TGTS" 2>&1 | tail -20
echo "ZFS_SO_PREBUILD_RC=$?"
ls -l $OUTDIR/libsolaris.so $OUTDIR/zpool.so $OUTDIR/zfs.so 2>&1 | head

docker exec bld bash -lc "cd /work/osv && ./scripts/build -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs --use-openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl" 2>&1 | tail -80
echo "BUILD_RC_UNRELIABLE=$?  (scripts/build exits 0 on module failure - check artifacts)"

echo "=== ARTIFACTS ==="
for f in build/last/usr.img build/last/loader.elf; do
  [ -f "$f" ] && echo "SIZE $f $(stat -c %s $f) ($(du -h $f|cut -f1))"
done
echo "=== IMAGE SIZE (expect ~119MB rofs; ~8MB = PG-FREE FAILURE) ==="
du -m build/last/usr.img 2>/dev/null
echo "=== postgres in image? ==="
grep -c postgres build/last/usr.manifest 2>/dev/null
ls -la apps/postgres18-musl/install/bin/postgres 2>/dev/null || echo "NO PG BINARY BUILT"
apps/postgres18-musl/install/bin/postgres --version 2>/dev/null || true
echo BUILD_DONE
