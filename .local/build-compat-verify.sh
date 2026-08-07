#!/usr/bin/env bash
# Verify PR 0 (pr/build-compat) builds a full kernel on meh's gcc-14/boost-1.87
# WITHOUT forcing any make vars (the commit itself defaults conf_cxx_level to
# gnu++14). musl stays at the master-era 1.1.24 pin. fs=zfs to match the sweep.
set -uo pipefail
T=/scratch/gburd/sweep/osv
BOOST=/nix/store/09yk6h7338qww8jzq2vf8vphffg8zxqh-boost-1.87.0-dev
cd "$T" || exit 2

git fetch origin pr/build-compat:pr/build-compat --force 2>&1 | tail -2
git checkout --force pr/build-compat 2>&1 | tail -2
git clean -xfd 2>&1 | tail -2
git submodule update --init --force musl_1.1.24 2>&1 | tail -2
echo "musl HEAD: $(git -C musl_1.1.24 rev-parse HEAD)"

nix-shell -p boost ncurses flex bison --run "
  OSV_NO_JAVA_TESTS=1 ./scripts/build -j$(nproc) OSV_NO_JAVA_TESTS=1 \
    fs=zfs image=empty boost_base=$BOOST \
    2>&1 | tee /scratch/gburd/build-compat.log | \
    grep -aE 'error:|undefined reference|conditional_t|lower_bound|Aborted|^Created|usr.img|libsolaris' | tail -40
"
echo "===BUILD_COMPAT_RC=${PIPESTATUS[0]}==="
tail -8 /scratch/gburd/build-compat.log
echo "===BUILD_COMPAT_DONE==="
