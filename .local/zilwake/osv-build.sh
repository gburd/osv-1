#!/bin/bash
# Native Debian 12 build of the minimal OSv OpenZFS image + zfs-bench.so.
# NO container (qemu 7.2 on Debian boots OSv natively; the build host is Debian too).
set -x
exec > /home/admin/osv-build.log 2>&1
echo "=== START $(date) ==="
cd /home/admin/osv
echo "OSV_HEAD=$(git rev-parse HEAD)"
echo "BRANCH=$(git branch --show-current)"
echo "SYNCWRITE_MT_PRESENT=$(grep -c wl_syncwrite_mt scripts/bench/zfs-bench.c)"
echo "ZILWAKE_PATCH_PRESENT=$(ls modules/open_zfs/patches/0034-*.patch 2>&1)"
echo "ZFS_SHA=$(git -C modules/open_zfs/openzfs rev-parse HEAD 2>&1)"

# a few extra deps Debian may need for the OSv build
export DEBIAN_FRONTEND=noninteractive
sudo apt-get install -y libboost-program-options-dev libboost-system-dev \
  libssl-dev libedit-dev tcpdump gdb qemu-utils lz4 liblz4-dev libzstd-dev \
  zlib1g-dev uuid-dev libblkid-dev python3-dnf 2>&1 | tail -3 || true

NPROC=$(nproc)
OUTDIR=build/release.x64
ZFSSOS="libsolaris.so zpool.so zfs.so libzfs.so libuutil.so libzfs_core.so libzutil.so libshare.so libtpool.so"
TGTS=""; for s in $ZFSSOS; do TGTS="$TGTS $OUTDIR/$s"; done

# Build the ZFS kernel + tools. The Makefile applies the OpenZFS patch series
# ONE AT A TIME (our fix); watch for OZFS-PATCH-SKIPPED lines.
make -j$NPROC conf_fork=1 conf_zfs=openzfs fs=rofs OSV_NO_JAVA_TESTS=1 $TGTS 2>&1 | tail -30
echo "ZFS_SO_RC=${PIPESTATUS[0]}"

# VERIFY the probe actually landed in the patched (built) source -- the Makefile
# swallows git-apply errors, so trust the grep, not the build success.
echo "=== VERIFY ZILWAKE PROBE IN BUILT SOURCE ==="
grep -c 'zilwake_dump\|OSV_ZIL_WAKE_UNLOCKED\|zw_fanouts' modules/open_zfs/openzfs/module/zfs/zil.c
echo "=== VERIFY zilwake_dump symbol EXPORTED in libsolaris.so ==="
nm -D $OUTDIR/libsolaris.so 2>/dev/null | grep -i zilwake_dump || echo "MISSING_zilwake_dump_symbol"

ls -l $OUTDIR/libsolaris.so $OUTDIR/zpool.so $OUTDIR/zfs.so 2>&1 | head

# Build the bench .so + relink zfs_builder.elf (native gcc, no container).
bash scripts/bench/rebuild-bench.sh openzfs 2>&1 | tail -20
echo "BENCH_RC=${PIPESTATUS[0]}"

echo "=== ARTIFACTS ==="
ls -l $OUTDIR/zfs_builder.elf $OUTDIR/zfs-bench.so $OUTDIR/zpool.so $OUTDIR/zfs.so 2>&1
echo "=== bench .so symbol gate (must be empty) ==="
nm -D $OUTDIR/zfs-bench.so | grep -E 'GLIBCXX|CXXABI|__isoc23' && echo "GATE_FAIL_bad_symbols" || echo "GATE_OK_no_bad_symbols"
echo "=== zfs-bench.so references zilwake_dump (weak)? ==="
nm -D $OUTDIR/zfs-bench.so | grep -i zilwake || echo "(weak undef -- resolved from libsolaris at load)"
echo "=== END $(date) ==="
echo OSV_BUILD_DONE
