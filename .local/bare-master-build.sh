#!/usr/bin/env bash
# Control experiment: does BARE upstream/master (8d2d4c89) build on meh's
# gcc-14 toolchain at all? Two passes:
#   pass A: default conf_cxx_level (gnu++11, as upstream ships)
#   pass B: forced conf_cxx_level=gnu++14
# If master itself fails the same way exp/musl-on-master did (core/mmu.cc
# <algorithm>/lower_bound), then that error is a toolchain-compat issue
# orthogonal to musl.
set -uo pipefail
T=/scratch/gburd/sweep/osv
BOOST=/nix/store/09yk6h7338qww8jzq2vf8vphffg8zxqh-boost-1.87.0-dev
cd "$T" || exit 2

git fetch upstream master 2>&1 | tail -2 || git fetch origin master 2>&1 | tail -2
git checkout --force 8d2d4c89 2>&1 | tail -2
git clean -xfd 2>&1 | tail -2
git submodule update --init --force musl_1.1.24 2>&1 | tail -2
echo "musl HEAD (should be 1.1.24-era): $(git -C musl_1.1.24 rev-parse HEAD)"

for LEVEL in gnu++11 gnu++14; do
  echo "========== PASS conf_cxx_level=$LEVEL =========="
  nix-shell -p boost ncurses flex bison --run "
    OSV_NO_JAVA_TESTS=1 make -j$(nproc) OSV_NO_JAVA_TESTS=1 \
      conf_cxx_level=$LEVEL boost_base=$BOOST \
      2>&1 | tee /scratch/gburd/bare-master-$LEVEL.log | \
      grep -aE 'error:|undefined reference|lower_bound|conditional_t|^OK|Aborted' | tail -25
  "
  echo "===RC_$LEVEL=${PIPESTATUS[0]}==="
done
echo "===BARE_MASTER_DONE==="
