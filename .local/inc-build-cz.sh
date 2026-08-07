#!/usr/bin/env bash
set -uo pipefail
cd /scratch/gburd/osv-build
export OSV_NO_JAVA_TESTS=1
BOOST=/nix/store/09yk6h7338qww8jzq2vf8vphffg8zxqh-boost-1.87.0-dev
echo "=== incremental build (crucible profile) ==="
nix-shell -p boost ncurses pkg-config --run "
  scripts/build fs=zfs fs_size_mb=4096 image=zfs-test \
    conf_drivers_profile=crucible \
    boost_base=$BOOST \
    zfs_builder_mem=4096 -j16
"
rc=$?
echo "===BUILD_DONE rc=$rc==="
echo -n "crucible symbols in loader: "
nm build/release.x64/loader.elf | grep -ic crucible
ls -la --time-style=+%s build/release.x64/loader.elf build/release.x64/drivers/crucible-client.o
