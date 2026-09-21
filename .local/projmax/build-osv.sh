#!/bin/bash
# Build the NATIVE OSv PG18 image for the native-substrate ratio curve.
#
# BASE: gh-fork/bench/native-substrate = 1480fbee1 (bank/fork-footprint-reduction-signed,
#   which ALREADY CARRIES #1478's 4 native-ZFS hunks: zfsdev_init on the preload path,
#   RTLD_GLOBAL, /etc/mnttab, preload-before-pivot, + the open_zfs module.py manifest entry)
#   + 1600b68cb (RDSEED + cpuid plumbing, BLOCKER 2) + an RNGPROOF lever line.
# apps pinned 3f93f43 (seed_copy mkdir gate == 1).
#
# fs=ramfs is LOAD-BEARING: the native fork wall is the ROFS-demand-page-nested-in-fork
# fault; fs=ramfs bakes postgres .text into the loader so it never demand-pages.
# The ZFS pool is then created at RUNTIME on the raw local NVMe (/dev/vblk0 = nvme0n1)
# via the #1478 preload path -- that is exactly what BLOCKER 1 unblocked.
#
# REFUSES to build if the base gate or any required marker is missing.
set -x
cd /work || exit 1
exec > /work/build-osv.log 2>&1

WANT_SHA="${WANT_SHA:?}"
rm -rf /work/osv
git clone --recurse-submodules -j8 https://github.com/gburd/osv-1.git /work/osv 2>&1 | tail -3
cd /work/osv || exit 1
git fetch origin bench/projected-max 2>&1 | tail -2
git checkout -f -B bench FETCH_HEAD || exit 1
git submodule update --init --recursive 2>&1 | tail -5

git -C apps remote get-url gha 2>/dev/null || git -C apps remote add gha https://github.com/gburd/osv-apps.git
git -C apps fetch gha 2>&1 | tail -2
git -C apps checkout -B benchapps 3f93f43f4f44f9e28dadceafe6aeffa9317a6fd3 || { echo "FATAL: cannot pin apps"; exit 1; }

echo "=== IDENTITY ==="
GOT=$(git rev-parse HEAD); echo "OSV_SHA=$GOT (want $WANT_SHA)"
[ "$GOT" = "$WANT_SHA" ] || { echo "FATAL: base SHA mismatch"; exit 1; }
echo "APPS_SHA=$(git -C apps rev-parse HEAD)"
git -C apps rev-parse HEAD | grep -q '^3f93f43' || { echo "FATAL: apps pin wrong"; exit 1; }
MKG=$(grep -c 'mkdir(dst, 0700)' apps/postgres18-musl/seed_copy.c)
echo "SEEDCOPY_MKDIR_FIX=$MKG (expect 1)"
[ "$MKG" = "1" ] || { echo "FATAL: apps mkdir gate != 1"; exit 1; }

echo "=== BASE GATE ==="
sh /work/bench-base-gate.sh /work/osv || { echo "FATAL: BASE GATE FAIL"; exit 1; }

echo "=== NATIVE-BLOCKER MARKERS (the two blockers the brief names) ==="
# BLOCKER 1: #1478's native-ZFS enablement, all four pieces.
B1_ZFSDEV=$(grep -c 'zfsdev::zfsdev_init()' loader.cc)
B1_MNTTAB=$(grep -c '/etc/mnttab' loader.cc)
B1_GLOBAL=$(grep -c 'RTLD_GLOBAL' loader.cc)
B1_MANIFEST=$(grep -c 'libsolaris.so: libsolaris.so' modules/open_zfs/module.py)
echo "B1_ZFSDEV_INIT=$B1_ZFSDEV (expect >=2: fs=zfs path + preload path)"
echo "B1_MNTTAB=$B1_MNTTAB (expect >=1)"
echo "B1_RTLD_GLOBAL=$B1_GLOBAL (expect >=1)"
echo "B1_MANIFEST_ENTRY=$B1_MANIFEST (expect 1)"
# The preload must run BEFORE the root-mount/pivot block, else the bootfs dlopen fails.
PRELOAD_LINE=$(grep -n 'opt_preload_zfs_library) {' loader.cc | head -1 | cut -d: -f1)
MOUNT_LINE=$(grep -n 'ZFS preload moved earlier' loader.cc | head -1 | cut -d: -f1)
echo "B1_PRELOAD_LINE=$PRELOAD_LINE B1_OLD_SITE_LINE=$MOUNT_LINE (preload must be the SMALLER)"
# BLOCKER 2: RDSEED + cpuid plumbing.
B2_RDSEED_DRV=$(grep -c 'rdseed' drivers/random.cc)
B2_RDSEED_CPUID=$(grep -c 'rdseed' arch/x64/cpuid.cc arch/x64/cpuid.hh arch/x64/processor.hh | tr '\n' ' ')
B2_PROOF=$(grep -c 'RNGPROOF' drivers/random.cc)
echo "B2_RDSEED_DRIVER=$B2_RDSEED_DRV (expect >=5)"
echo "B2_RDSEED_CPUID=$B2_RDSEED_CPUID"
echo "B2_RNGPROOF=$B2_PROOF (expect 1, the lever-proof printf)"
# Nitro driver fixes the prior native run needed (must already be in the base).
N_ENA=$(grep -c 'indirection' bsd/sys/dev/ena/ena.cc)
N_NVME=$(grep -c 'io_queues_count' drivers/nvme.cc)
echo "NITRO_ENA_RSS=$N_ENA (expect >=1)"
echo "NITRO_NVME_MSIX_CAP=$N_NVME (expect >=2)"
for chk in "$B1_ZFSDEV:2" "$B1_MNTTAB:1" "$B1_GLOBAL:1" "$B1_MANIFEST:1" "$B2_RDSEED_DRV:5" "$B2_PROOF:1" "$N_ENA:1" "$N_NVME:2"; do
  v="${chk%%:*}"; n="${chk##*:}"
  [ "$v" -ge "$n" ] || { echo "FATAL: native-blocker marker $v < $n"; exit 1; }
done
[ "$PRELOAD_LINE" -lt "$MOUNT_LINE" ] || { echo "FATAL: ZFS preload is NOT before the pivot"; exit 1; }
echo "NATIVE_MARKERS_OK"

echo "=== footprint FIX + probe markers ==="
for chk in "ovf_window_sz:core/fork_arena.cc:6" "ovf_owner_slot:core/fork_arena.cc:3" \
           "FORK_OVF_RECYCLE_DEFAULT:core/fork_arena.cc:2" "FORKARENA ovf_recycle:core/fork_arena.cc:1" \
           "fp_dump_once:core/mmu.cc:2" "fp_probe_start:loader.cc:1"; do
  k="${chk%%:*}"; rest="${chk#*:}"; f="${rest%%:*}"; n="${rest##*:}"
  c=$(grep -c -F -- "$k" "$f")
  echo "  marker $k = $c (need >=$n)"
  [ "$c" -ge "$n" ] || { echo "FATAL: marker '$k' in $f = $c, need >=$n"; exit 1; }
done

cat > /work/incontainer.sh <<'EOS'
set -x
cd /work/osv
dnf install -y gcc gcc-c++ libstdc++-static glibc-static
dnf install -y --skip-broken flex bison git make cmake python3 python3-pip python3-setuptools perl perl-FindBin \
  perl-IPC-Cmd perl-Data-Dumper perl-File-Compare perl-File-Copy gawk util-linux shadow-utils \
  openssl-devel libedit-devel boost-devel genromfs autoconf automake libtool \
  ncurses-devel bzip2 patch wget curl qemu-img qemu-system-x86 \
  musl-gcc musl-libc-static musl-devel gnutls-devel libaio-devel elfutils-libelf-devel \
  zlib-devel libuuid-devel libblkid-devel openssl libtirpc-devel lz4-devel libzstd-devel \
  file which findutils tar gzip xz binutils bc unzip
pip3 install requests distro 2>&1 | tail -2
python3 -c 'import distro; print("DISTRO_OK", distro.id())'
which musl-gcc; musl-gcc --version | head -1
EOS

sudo docker pull fedora:39 || exit 1
sudo docker rm -f bld 2>/dev/null
sudo docker run -d --name bld --privileged --network host -v /work:/work fedora:39 sleep infinity
sudo docker exec bld bash /work/incontainer.sh || { echo "FATAL: container deps"; exit 1; }

NPROC=$(nproc)
OUT=build/release.x64
# ZFS userspace .so's must exist BEFORE the image build packs them.
ZFSSOS="libsolaris.so zpool.so zfs.so libzfs.so libuutil.so libzfs_core.so libzutil.so libshare.so libtpool.so"
TGTS=""; for s in $ZFSSOS; do TGTS="$TGTS $OUT/$s"; done
# Parse the Makefile once so the OpenZFS patch series (which CREATES the OSv
# platform layer, including module/os/osv/zfs/arc_os.c) is applied before the
# ARC probe is inserted into it.
#
# This parse legitimately fails on a fresh tree: kernel_conf.mk is generated
# later, so make stops with "No rule to make target .../kernel_conf.mk". The
# patch series has already been applied by then (it runs during parse), so that
# failure is benign and must be tolerated.
#
# What must NOT be tolerated is a patch that did not apply. Previously this line
# read `>/dev/null 2>&1 || true`, which threw away the only diagnostic the apply
# chain produced -- that is how patch 0032 stayed silently unapplied across every
# build of this campaign. So: keep stderr, and check the specific condition.
sudo docker exec bld bash -lc "cd /work/osv && make -n conf_fork=1 conf_zfs=openzfs fs=ramfs $OUT/libsolaris.so >/dev/null" 2>&1 | tee /work/ozfs-parse.log | grep -vE 'kernel_conf.mk|No rule to make target' || true
if grep -q 'refusing to build ZFS from an incompletely patched tree' /work/ozfs-parse.log; then
  echo "FATAL: OpenZFS patch series is INCOMPLETE:"; grep -A6 'patch series is INCOMPLETE' /work/ozfs-parse.log; exit 1
fi
if sudo test -f /work/osv/modules/open_zfs/openzfs/.osv-patches-failed; then
  echo "FATAL: these OpenZFS patches did not apply:"; sudo cat /work/osv/modules/open_zfs/openzfs/.osv-patches-failed; exit 1
fi
echo "OZFS_PATCH_SERIES_OK (0 skipped)"
echo "--- patches that needed a --recount rescue (wrong hunk counts, applied anyway):"
sudo cat /work/osv/modules/open_zfs/openzfs/.osv-patches-log 2>/dev/null || echo "  (none)"
sudo ls -l modules/open_zfs/openzfs/module/os/osv/zfs/arc_os.c || { echo "FATAL: OpenZFS OSv platform layer not patched in"; exit 1; }
grep -c 'OZFS-PATCH' /work/build-osv.log

# ARC MEASUREMENT PROBE (default-on: the brief requires MEASURED arc_c/arc_size,
# never an asserted cap. printf reaches the console; debugf is verbose-gated).
# Run INSIDE the container: the patch series ran as root there, so the OSv
# platform-layer sources are root-owned on the host mount.
sudo docker exec bld bash -lc "cd /work && python3 /work/insert-arc-probe.py" || { echo "FATAL: arc probe"; exit 1; }
sudo docker exec bld bash -lc "grep -c osv_arc_probe /work/osv/modules/open_zfs/openzfs/module/os/osv/zfs/arc_os.c"

sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=ramfs $TGTS" 2>&1 | tail -15
ls -l $OUT/libsolaris.so $OUT/zpool.so 2>&1 | head

# fs=ramfs bootfs RACE (banked in NATIVE-TAIL-RESULT): mount-fs.so/umount.so are
# referenced by usr_ramfs.manifest.skel but are not a bootfs.bin prerequisite, so
# under -j they are missing -> mkbootfs FileNotFoundError. Build them FIRST.
sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=ramfs $OUT/tools/mount/mount-fs.so $OUT/tools/mount/umount.so" 2>&1 | tail -5

sudo docker exec bld bash -lc "cd /work/osv && ./scripts/build -j$NPROC conf_fork=1 conf_zfs=openzfs fs=ramfs --use-openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl" 2>&1 | tail -40

echo "=== ARTIFACTS ==="
ls -l $OUT/bare.raw $OUT/loader.elf $OUT/loader.img 2>&1
echo "LOADER_MB=$(du -m $OUT/loader.elf 2>/dev/null | cut -f1)  (ramfs+PG baked: expect >150MB; ~8MB = PG-FREE FAILURE)"
echo "BARE_MB=$(du -m $OUT/bare.raw 2>/dev/null | cut -f1)"
echo "POSTGRES_IN_MANIFEST=$(grep -c postgres $OUT/usr.manifest 2>/dev/null)"
echo "LIBSOLARIS_IN_MANIFEST=$(grep -c libsolaris $OUT/usr.manifest 2>/dev/null)  (expect 1: BLOCKER 1 manifest fix)"
echo "ZPOOL_IN_MANIFEST=$(grep -c 'zpool.so' $OUT/usr.manifest 2>/dev/null)"
echo "CONF_FORK=$(grep -c '^CONF_fork=y' conf/base.mk build/release.x64/gen/include/osv/../../../../.config 2>/dev/null | tr '\n' ' ')"
grep -E '^CONF_(fork|zfs)' .config 2>/dev/null
echo BUILD_OSV_DONE
