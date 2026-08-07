#!/usr/bin/env bash
# Test whether musl 1.2.1 builds on BARE upstream/master (exp/musl-on-master),
# WITHOUT the build-nix commit. The only build-nix-derived knob we allow is
# conf_cxx_level=gnu++14, which is forced by meh's boost 1.87 (a build-ENV
# concern), not by musl itself. If this builds + boots, musl is proven
# independent of build-nix.
set -uo pipefail
T=/scratch/gburd/sweep/osv
BOOST=/nix/store/09yk6h7338qww8jzq2vf8vphffg8zxqh-boost-1.87.0-dev
cd "$T" || exit 2

echo "=== fetch + checkout exp/musl-on-master ==="
git fetch origin exp/musl-on-master:exp/musl-on-master --force 2>&1 | tail -3
git checkout --force exp/musl-on-master 2>&1 | tail -3
git clean -xfd 2>&1 | tail -2

echo "=== sync musl submodule to 1.2.1 pin ==="
git submodule sync musl_1.1.24 2>&1 | tail -2
git submodule update --init --force musl_1.1.24 2>&1 | tail -3
echo "musl HEAD: $(git -C musl_1.1.24 rev-parse HEAD)"

echo "=== build (gnu++14 forced; NO other build-nix bits) ==="
nix-shell -p boost ncurses flex bison --run "
  OSV_NO_JAVA_TESTS=1 make -j$(nproc) OSV_NO_JAVA_TESTS=1 \
    conf_cxx_level=gnu++14 \
    boost_base=$BOOST \
    2>&1 | tee /scratch/gburd/musl-on-master-build.log | \
    grep -aE 'error:|Error|undefined reference|cannot find|No such file|LINK|^OK|Aborted|conditional_t' | tail -60
"
RC=${PIPESTATUS[0]}
echo "===BUILD_RC=$RC==="
echo "=== last 20 lines of full log ==="
tail -20 /scratch/gburd/musl-on-master-build.log
echo "===MUSL_ON_MASTER_DONE==="
