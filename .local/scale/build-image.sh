#!/bin/bash
# Build the OSv PG18 image for the SCALE RE-TEST, from the FIXED tree:
#   gh-fork/bank/fork-footprint-reduction-signed @ 1480fbee1 (5 commits, all G-signed)
#   apps pinned to 3f93f43 (seed_copy mkdir gate == 1)
# The footprint fix's arm is COMPILE-TIME (FORK_OVF_RECYCLE_DEFAULT, default 1 = AFTER/fixed).
# REFUSES to build if the base gate or any fix/probe marker is missing.
set -x
BR="${1:-bank/fork-footprint-reduction-signed}"
TAG="${2:-fix}"
WANT_SHA="${3:-1480fbee17574fa8949895eddf0fb47b01b4f5a7}"
cd /work/osv || exit 1
exec > /work/build-$TAG.log 2>&1

git remote get-url gh 2>/dev/null || git remote add gh https://github.com/gburd/osv-1.git
git fetch gh --tags 2>&1 | tail -3
git checkout -f -B bench "gh/$BR" || exit 1
git submodule update --init --recursive apps modules/open_zfs/openzfs musl_1.2.1 external/x64/* 2>/dev/null
git submodule update --init --recursive 2>&1 | tail -5

# apps pinned to 3f93f43 (the seed_copy rofs-mode fix), NOT the recorded gitlink.
git -C apps remote get-url gha 2>/dev/null || git -C apps remote add gha https://github.com/gburd/osv-apps.git
git -C apps fetch gha 2>&1 | tail -2
git -C apps checkout -B benchapps 3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3 || { echo "FATAL: cannot pin apps"; exit 1; }

echo "=== IDENTITY (must match the brief) ==="
GOT=$(git rev-parse HEAD)
echo "OSV_SHA=$GOT  (want $WANT_SHA)"
[ "$GOT" = "$WANT_SHA" ] || { echo "FATAL: base SHA mismatch"; exit 1; }
echo "APPS_SHA=$(git -C apps rev-parse HEAD)"
git -C apps rev-parse HEAD | grep -q '^3f93f43' || { echo "FATAL: apps pin wrong"; exit 1; }
MKG=$(grep -c 'mkdir(dst, 0700)' apps/postgres18-musl/seed_copy.c)
echo "SEEDCOPY_MKDIR_FIX=$MKG  (expect 1)"
[ "$MKG" = "1" ] || { echo "FATAL: apps mkdir gate != 1"; exit 1; }
echo "=== G-signature check on the 5 commits ==="
git log --format='%h %G? %s' -5 HEAD
NG=$(git log --format='%G?' -5 HEAD | grep -cv '^G$')
echo "UNSIGNED_OF_5=$NG (expect 0)"
PH=$(grep -c 'PHONY: module build' apps/postgres18-musl/Makefile)
if [ "$PH" != "1" ]; then sed -i '1i .PHONY: module build' apps/postgres18-musl/Makefile; fi

echo "=== base gate (refuse to bench a base missing a required fix) ==="
sh /work/bench-base-gate.sh /work/osv || { echo "FATAL: BASE GATE FAIL"; exit 1; }

echo "=== footprint FIX + PROBE markers ==="
echo "FIX_WINDOW=$(grep -c ovf_window_sz core/fork_arena.cc)      (expect >=6)"
echo "FIX_OWNER=$(grep -c ovf_owner_slot core/fork_arena.cc)      (expect >=3)"
echo "FIX_RECYCLE_DEFAULT=$(grep -c FORK_OVF_RECYCLE_DEFAULT core/fork_arena.cc) (compile-time A/B)"
echo "FIX_PROOFLINE=$(grep -c 'FORKARENA ovf_recycle' core/fork_arena.cc)  (the resolved-value proof line)"
echo "FP_DUMP=$(grep -c fp_dump_once core/mmu.cc)                 (expect 2)"
echo "FP_LOADER=$(grep -c fp_probe_start loader.cc)               (expect 1)"
echo "FP_DEBUG_EARLY=$(grep -c 'debug_early_u64(\" memfree_MB=' core/mmu.cc) (probe uses debug_early not debugf)"
for chk in "ovf_window_sz:core/fork_arena.cc:6" "ovf_owner_slot:core/fork_arena.cc:3" \
           "FORK_OVF_RECYCLE_DEFAULT:core/fork_arena.cc:2" "FORKARENA ovf_recycle:core/fork_arena.cc:1" \
           "fp_dump_once:core/mmu.cc:2" "fp_probe_start:loader.cc:1"; do
  k="${chk%%:*}"; rest="${chk#*:}"; f="${rest%%:*}"; n="${rest##*:}"
  c=$(grep -c -F -- "$k" "$f")
  [ "$c" -ge "$n" ] || { echo "FATAL: marker '$k' in $f = $c, need >=$n"; exit 1; }
done
echo "ALL_MARKERS_OK"

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
sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs $TGTS" 2>&1 | tail -20
ls -l $OUTDIR/libsolaris.so $OUTDIR/zpool.so 2>&1 | head

sudo docker exec bld bash -lc "cd /work/osv && ./scripts/build -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs --use-openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl" 2>&1 | tail -40

echo "=== ARTIFACTS ==="
for f in build/last/usr.img build/last/loader.elf; do
  [ -f "$f" ] && echo "SIZE $f $(stat -c %s $f)"
done
echo "=== IMAGE SIZE (expect ~119MB rofs; ~8MB = PG-FREE FAILURE) ==="
du -m build/last/usr.img 2>/dev/null
echo "POSTGRES_IN_MANIFEST=$(grep -c postgres build/last/usr.manifest 2>/dev/null)"
echo BUILD_STAGE1_DONE_$TAG
