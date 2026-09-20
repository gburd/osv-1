#!/bin/bash
# Build the OSv PG18 image on the metal host in a fedora:39 container, WITH the
# footprint probe (OSV_FP_PROBE) + the extended MEMPROBE sampler.
# Base = gh-fork/bank/fork-arena-real-reclaim (VERIFIED base, gate PASS), apps 3f93f43.
set -x
BR="${1:-bank/fork-arena-real-reclaim}"
TAG="${2:-fp}"
cd /work/osv || exit 1
exec > /work/build-$TAG.log 2>&1

git remote get-url gh 2>/dev/null || git remote add gh https://github.com/gburd/osv-1.git
git fetch gh --tags 2>&1 | tail -3
git checkout -f -B bench "gh/$BR" || exit 1
git submodule update --init --recursive apps modules/open_zfs/openzfs musl_1.2.1 external/x64/* 2>/dev/null
git submodule update --init --recursive 2>&1 | tail -5
git -C modules/open_zfs/openzfs checkout -- . 2>/dev/null

# apps must be pinned to 3f93f43 (the seed_copy rofs-mode fix), NOT the recorded gitlink.
git -C apps remote get-url gha 2>/dev/null || git -C apps remote add gha https://github.com/gburd/osv-apps.git
git -C apps fetch gha 2>&1 | tail -2
git -C apps checkout -B benchapps 3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3 || echo "FATAL: cannot pin apps to 3f93f43"

echo "=== IDENTITY ==="
echo "OSV_SHA=$(git rev-parse HEAD)"
echo "APPS_SHA=$(git -C apps rev-parse HEAD)"
git -C apps rev-parse HEAD | grep -q '^3f93f43' || echo "FATAL: apps pin wrong: $(git -C apps rev-parse HEAD)"
echo "SEEDCOPY_MKDIR_FIX=$(grep -c 'mkdir(dst, 0700)' apps/postgres18-musl/seed_copy.c)  (expect 1)"
PH=$(grep -c 'PHONY: module build' apps/postgres18-musl/Makefile)
if [ "$PH" != "1" ]; then sed -i '1i .PHONY: module build' apps/postgres18-musl/Makefile; fi

echo "=== base gate markers ==="
echo "stack_guard=$(grep -c stack_guard arch/x64/arch-tls.hh)  (expect 3)"
echo "wake_pull_enabled=$(grep -c 'wake_pull_enabled = true' core/sched.cc)  (expect 1)"
echo "OSV_FORK_RANGE_BS=$(grep -c OSV_FORK_RANGE_BS core/mmu.cc)  (expect 2)"
echo "OSV_FORK_LARGE_SHARE=$(grep -c OSV_FORK_LARGE_SHARE core/mmu.cc)  (expect 2)"

# ---- APPLY THE FOOTPRINT PROBES (idempotent) ----
python3 /work/insert-fp-probe.py /work/osv/core/mmu.cc /work/osv/loader.cc || { echo "FATAL: fp probe"; exit 1; }
echo "FP_PROBE_MARKERS=$(grep -c fp_count_cow core/mmu.cc)  (expect >=4)"
echo "FP_DUMP_MARKER=$(grep -c fp_dump_once core/mmu.cc)  (expect 2)"
echo "FP_LOADER_MARKER=$(grep -c fp_probe_start loader.cc)  (expect 1)"
echo "FP_ARENA_MARKER=$(grep -c bump_used core/fork_arena.cc)  (expect 1)"

# ---- EXTRA FIX APPLIERS (STEP 2, optional; each idempotent, env-gated) ----
for p in /work/fix-*.py; do
  [ -f "$p" ] || continue
  echo "=== applying $p ==="
  python3 "$p" || echo "FIX-APPLY-FAILED $p"
done

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

sudo docker pull fedora:39
sudo docker rm -f bld 2>/dev/null
sudo docker run -d --name bld --privileged --network host -v /work:/work fedora:39 sleep infinity
sudo docker exec bld bash /work/incontainer.sh || { echo "FATAL: container deps"; exit 1; }

NPROC=$(nproc)
OUTDIR=build/release.x64
ZFSSOS="libsolaris.so zpool.so zfs.so libzfs.so libuutil.so libzfs_core.so libzutil.so libshare.so libtpool.so"
TGTS=""; for s in $ZFSSOS; do TGTS="$TGTS $OUTDIR/$s"; done
sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs $TGTS" 2>&1 | tail -30
ls -l $OUTDIR/libsolaris.so $OUTDIR/zpool.so 2>&1 | head

sudo docker exec bld bash -lc "cd /work/osv && ./scripts/build -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs --use-openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl" 2>&1 | tail -60

echo "=== ARTIFACTS ==="
for f in build/last/usr.img build/last/loader.elf; do
  [ -f "$f" ] && echo "SIZE $f $(stat -c %s $f) ($(du -h $f|cut -f1))"
done
echo "=== IMAGE SIZE (expect ~119MB rofs; ~8MB = PG-FREE FAILURE) ==="
du -m build/last/usr.img 2>/dev/null
echo "=== postgres in image? ==="
grep -c postgres build/last/usr.manifest 2>/dev/null
apps/postgres18-musl/install/bin/postgres --version 2>/dev/null || echo "NO PG BINARY"
# snapshot this image under the tag so A/B images do not overwrite each other
mkdir -p /work/img-$TAG
cp -f build/last/usr.img /work/img-$TAG/usr.img 2>/dev/null
cp -f build/last/loader.elf /work/img-$TAG/loader.elf 2>/dev/null
ls -l /work/img-$TAG/
echo BUILD_DONE_$TAG
