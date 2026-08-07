#!/usr/bin/env bash
set -uo pipefail
cd /scratch/gburd/osv-build
export OSV_NO_JAVA_TESTS=1
BOOST=/nix/store/09yk6h7338qww8jzq2vf8vphffg8zxqh-boost-1.87.0-dev

echo "=== make clean ==="
nix-shell -p boost ncurses pkg-config flex bison --run "scripts/build clean boost_base=$BOOST" 2>&1 | tail -5

echo "=== clean build ==="
nix-shell -p boost ncurses pkg-config flex bison --run "
  scripts/build fs=zfs fs_size_mb=4096 image=zfs-test \
    conf_drivers_profile=crucible \
    boost_base=$BOOST \
    zfs_builder_mem=4096 -j16
" 2>&1
echo "===BUILD_DONE rc=$?==="
ls -la build/release.x64/loader.elf build/release.x64/libsolaris.so 2>&1
