#!/usr/bin/env bash
set -euo pipefail
cd /home/gburd/ws/osv

touch drivers/nvmeof-blk.cc drivers/nvmeof-client.cc drivers/nvmeof-connection.cc \
      drivers/nvmeof-blk.hh drivers/nvmeof-client.hh drivers/nvmeof-connection.hh \
      drivers/nvmeof-pdu.hh loader.cc

BOOST_BASE=$(nix eval --raw nixpkgs#boost.dev)
echo "BUILD_START boost=$BOOST_BASE arch=x86_64"

# Default kernel build (no fs image) for x86_64 with the nvmeof profile.
# This compiles the nvmeof driver objects and links loader.elf, which is
# what the symbol-presence verification gate inspects.
nix develop -c bash -c "make -j$(nproc) arch=x64 conf_drivers_profile=nvmeof boost_base='$BOOST_BASE' OSV_NO_JAVA_TESTS=1 build/release.x64/loader.elf" 2>&1

echo "BUILD_DONE"
echo "=== DRIVER OBJS ==="
ls -la build/release.x64/drivers/nvmeof*.o 2>&1
echo "=== NM GREP (with profile, x64) ==="
nm build/release.x64/loader.elf | grep -ic nvmeof || echo "0"
