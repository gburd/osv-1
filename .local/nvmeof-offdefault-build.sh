#!/usr/bin/env bash
set -euo pipefail
cd /home/gburd/ws/osv

# Off-by-default verification: same x64 kernel WITHOUT conf_drivers_profile.
# Force a relink by touching loader.cc; with the gate off the nvmeof driver
# objects must not be compiled and no nvmeof symbol may appear in loader.elf.
touch loader.cc

BOOST_BASE=$(nix eval --raw nixpkgs#boost.dev)
echo "BUILD_START (NO profile) boost=$BOOST_BASE"

nix develop -c bash -c "make -j$(nproc) arch=x64 boost_base='$BOOST_BASE' OSV_NO_JAVA_TESTS=1 build/release.x64/loader.elf" 2>&1

echo "BUILD_DONE"
echo "=== DRIVER OBJS (expect ABSENT or stale) ==="
ls -la build/release.x64/drivers/nvmeof*.o 2>&1 || echo "no nvmeof objects"
echo "=== NM GREP (NO profile, x64) ==="
nm build/release.x64/loader.elf | grep -ic nvmeof || echo "0"
