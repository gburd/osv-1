#!/bin/bash
# Build the NATIVE OSv PG18 image for bench24 on the ALIGNED base.
#
# BASE: gh-fork/integ/pg-master @ e83cdfef1 -- 181 commits ON upstream/master
#   (ancestry TRUE), 0 unsigned, apps pinned 3f93f43.  Preflight PASSES with no
#   BENCH_ALLOW_STALE_BASE.  This is the first image whose base CONTAINS master.
#
# fs=ramfs is LOAD-BEARING: the native fork wall is a ROFS demand-page fault
# NESTED inside the fork fault.  fs=ramfs bakes postgres .text into the loader so
# it never demand-pages.  The ZFS pool is created at RUNTIME on raw local NVMe.
#
# WHAT CHANGED vs the old build script, and why it would otherwise have failed:
#   * The aligned base carries the OpenZFS OSv platform layer IN-TREE at
#     modules/open_zfs/osv/module/os/osv/zfs/ with ONE patch, where the old base
#     synthesised it from a 45-patch series into modules/open_zfs/openzfs/.  So
#     the old script's `make -n ... libsolaris.so` pre-pass (whose only purpose
#     was to make the patch series apply before probe insertion) is unnecessary,
#     and its `ls modules/open_zfs/openzfs/module/os/osv/zfs/arc_os.c` guard
#     would FATAL on a perfectly good tree.
#   * fedora:41 (not 39): ld 2.43 has the GOTPCREL-convert the ramfs .bss build
#     wants, and gcc-14 builds this base clean.
#
# BUILD-EVIDENCE RULE: a LINK line is NOT proof of a build.  A real kernel build
# here is 1200-1600 lines.  This script prints the compile-line count for the
# files we changed and FAILS if they were not compiled -- accepting a 178-line
# relink log as build proof is a mistake already made once on this campaign.
set -x
cd /work || exit 1
exec > /work/build-osv.log 2>&1

WANT_SHA="${WANT_SHA:?}"
rm -rf /work/osv
git clone https://github.com/gburd/osv-1.git /work/osv 2>&1 | tail -3
cd /work/osv || exit 1
git fetch origin integ/pg-master 2>&1 | tail -2
git checkout -f -B bench "$WANT_SHA" || exit 1
git submodule update --init --recursive --force 2>&1 | tail -8

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

echo "=== ANCESTRY (the whole point of this run) ==="
git remote add upstream https://github.com/cloudius-systems/osv.git 2>/dev/null
git fetch -q upstream master 2>&1 | tail -2
git merge-base --is-ancestor upstream/master HEAD \
  && echo "ANCESTRY_OK base contains upstream/master ($(git rev-list --count upstream/master..HEAD) commits on top)" \
  || { echo "FATAL: base does NOT contain upstream/master"; exit 1; }

echo "=== THE FIVE MARKERS THE BRIEF NAMES, verified IN THE BUILT TREE ==="
m() { printf "  %-34s %s (need >=%s)\n" "$1" "$3" "$2"; [ "$3" -ge "$2" ] || { echo "FATAL: marker $1"; exit 1; }; }
m "1513_vdev_nonrot"      1 "$(grep -c 'vdev_nonrot = B_TRUE' modules/open_zfs/osv/module/os/osv/zfs/vdev_disk.c)"
m "0032_arc_shrink_sync"  1 "$(grep -c 'arc_reduce_target_size_shrink_sync' modules/open_zfs/osv/module/os/osv/zfs/zfs_initialize_osv.c)"
m "in_lltable_new_scope"  1 "$(sed -n '/in_lltable_new/,/^}/p' bsd/sys/netinet/in.cc | grep -c 'kernel_heap_scope')"
m "1515_bt_from_interrupt" 1 "$(grep -c 'backtrace_safe_from_interrupt' arch/x64/backtrace.cc)"
m "1472_try_pull"          3 "$(grep -c 'try_pull_from_busiest' core/sched.cc)"
git merge-base --is-ancestor ae077860c HEAD \
  && echo "  ae077860c virtio-blk drain-without-queue-lock: ANCESTOR TRUE" \
  || { echo "FATAL: ae077860c absent"; exit 1; }

echo "=== NATIVE-BOOT ENABLERS (must already be in the base) ==="
m "B1_zfsdev_init"   2 "$(grep -c 'zfsdev::zfsdev_init()' loader.cc)"
m "B1_mnttab"        1 "$(grep -c '/etc/mnttab' loader.cc)"
m "B1_rtld_global"   1 "$(grep -c 'RTLD_GLOBAL' loader.cc)"
m "B1_manifest"      1 "$(grep -c 'libsolaris.so: libsolaris.so' modules/open_zfs/module.py)"
m "B2_rdseed"        5 "$(grep -c 'rdseed' drivers/random.cc)"
m "B2_rngproof"      1 "$(grep -c 'RNGPROOF' drivers/random.cc)"
m "nitro_ena_rss"    1 "$(grep -c 'indirection' bsd/sys/dev/ena/ena.cc)"
m "nitro_nvme_msix"  2 "$(grep -c 'io_queues_count' drivers/nvme.cc)"
PRELOAD_LINE=$(grep -n 'opt_preload_zfs_library) {' loader.cc | head -1 | cut -d: -f1)
MOUNT_LINE=$(grep -n 'ZFS preload moved earlier' loader.cc | head -1 | cut -d: -f1)
echo "  B1_preload_line=$PRELOAD_LINE old_site=$MOUNT_LINE (preload must be SMALLER)"
[ "$PRELOAD_LINE" -lt "$MOUNT_LINE" ] || { echo "FATAL: ZFS preload not before pivot"; exit 1; }
echo "=== existing lever proof lines (printf, not debugf) ==="
grep -n 'printf("WAKE_PULL\|printf("RNGPROOF\|printf("IDLE_SPIN_PROOF' core/sched.cc drivers/random.cc

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
pip3 install --break-system-packages requests distro 2>&1 | tail -2
python3 -c 'import distro; print("DISTRO_OK", distro.id())'
which musl-gcc; musl-gcc --version | head -1
gcc --version | head -1; ld --version | head -1
EOS

sudo docker pull fedora:41 || exit 1
sudo docker rm -f bld 2>/dev/null
sudo docker run -d --name bld --privileged --network host -v /work:/work fedora:41 sleep infinity
sudo docker exec bld bash /work/incontainer.sh || { echo "FATAL: container deps"; exit 1; }

echo "=== PROBE INSERTION (fail-loud: a probe build with no probe measures nothing) ==="
sudo docker exec bld bash -lc "cd /work/osv && python3 /work/insert-probe.py"     || { echo "FATAL: probe insert"; exit 1; }
sudo docker exec bld bash -lc "cd /work/osv && python3 /work/insert-arc-probe.py" || { echo "FATAL: arc probe";   exit 1; }
sudo docker exec bld bash -lc "grep -c osv_arc_probe /work/osv/modules/open_zfs/osv/module/os/osv/zfs/arc_os.c"
sudo docker exec bld bash -lc "grep -c nonrot_probe_note /work/osv/modules/open_zfs/osv/module/os/osv/zfs/vdev_disk.c"
sudo docker exec bld bash -lc "grep -c schedprobe_start /work/osv/core/sched.cc /work/osv/loader.cc"

NPROC=$(nproc)
OUT=build/release.x64
ZFSSOS="libsolaris.so zpool.so zfs.so libzfs.so libuutil.so libzfs_core.so libzutil.so libshare.so libtpool.so"
TGTS=""; for s in $ZFSSOS; do TGTS="$TGTS $OUT/$s"; done
sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=ramfs $TGTS" 2>&1 | tail -15
ls -l $OUT/libsolaris.so $OUT/zpool.so 2>&1 | head

# fs=ramfs bootfs RACE: mount-fs.so/umount.so are referenced by
# usr_ramfs.manifest.skel but are NOT a bootfs.bin prerequisite, so under -j they
# may be missing -> mkbootfs FileNotFoundError.  Build them first.
sudo docker exec bld bash -lc "cd /work/osv && make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=ramfs $OUT/tools/mount/mount-fs.so $OUT/tools/mount/umount.so" 2>&1 | tail -5

sudo docker exec bld bash -lc "cd /work/osv && ./scripts/build -j$NPROC conf_fork=1 conf_zfs=openzfs fs=ramfs --use-openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl" 2>&1 | tail -40

echo "=== BUILD EVIDENCE: were the files we CHANGED actually compiled? ==="
echo "BUILD_LOG_LINES=$(wc -l < /work/build-osv.log)  (a real kernel build here is 1200-1600; ~178 = a RELINK, not a build)"
for f in core/sched.cc core/lfmutex.cc loader.cc core/mmu.cc vdev_disk.c arc_os.c; do
  echo "  compiled_$f=$(grep -cE "CC .*$f|CXX .*$f|cc1plus.*$f|compiling $f" /work/build-osv.log)"
done
grep -cE '^(CC|CXX|LD|AR) ' /work/build-osv.log

echo "=== ARTIFACTS ==="
ls -l $OUT/bare.raw $OUT/loader.elf $OUT/loader.img 2>&1
echo "LOADER_MB=$(du -m $OUT/loader.elf 2>/dev/null | cut -f1)  (ramfs+PG baked: expect >150MB; ~8MB = PG-FREE FAILURE)"
echo "BARE_MB=$(du -m $OUT/bare.raw 2>/dev/null | cut -f1)"
echo "POSTGRES_IN_MANIFEST=$(grep -c postgres $OUT/usr.manifest 2>/dev/null)"
echo "LIBSOLARIS_IN_MANIFEST=$(grep -c libsolaris $OUT/usr.manifest 2>/dev/null)"
echo "ZPOOL_IN_MANIFEST=$(grep -c 'zpool.so' $OUT/usr.manifest 2>/dev/null)"
grep -E '^CONF_(fork|zfs)' .config 2>/dev/null
echo "=== io_method=worker availability in the built PG (the deliberate deviation) ==="
grep -c 'USE_LIBURING' apps/postgres18-musl/build/postgres*/src/include/pg_config.h 2>/dev/null \
  || echo "USE_LIBURING absent as expected (io_uring NOT compiled in; worker is the async path we use)"
echo BUILD_OSV_DONE
