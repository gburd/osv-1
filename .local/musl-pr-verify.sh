#!/usr/bin/env bash
# Verify PR 1 (pr/musl = pr/build-compat -> musl 1.2.1) builds on meh via the
# canonical scripts/build. musl re-pins to public v1.2.1 (73cc775b). Then run
# the libc/musl-behavior unit tests as Waldek's musl bar (proxy for "unit tests
# pass"): build a test image and boot a representative set.
set -uo pipefail
T=/scratch/gburd/sweep/osv
BOOST=/nix/store/09yk6h7338qww8jzq2vf8vphffg8zxqh-boost-1.87.0-dev
cd "$T" || exit 2

git fetch origin pr/musl:pr/musl --force 2>&1 | tail -2
git checkout --force pr/musl 2>&1 | tail -2
git clean -xfd 2>&1 | tail -2
git submodule sync musl_1.1.24 2>&1 | tail -1
git submodule update --init --force musl_1.1.24 2>&1 | tail -2
echo "musl HEAD (want 73cc775b v1.2.1): $(git -C musl_1.1.24 rev-parse HEAD)"

echo "=== BUILD pr/musl (default fs image with tests) ==="
nix-shell -p boost ncurses flex bison --run "
  OSV_NO_JAVA_TESTS=1 ./scripts/build -j$(nproc) OSV_NO_JAVA_TESTS=1 \
    fs=zfs image=tests boost_base=$BOOST \
    2>&1 | tee /scratch/gburd/musl-pr-build.log | \
    grep -aE 'error:|undefined reference|conditional_t|lower_bound|Aborted|^Created|usr.img|__string_read|libsolaris' | tail -40
"
echo "===MUSL_PR_BUILD_RC=${PIPESTATUS[0]}==="
tail -6 /scratch/gburd/musl-pr-build.log
echo "===MUSL_PR_BUILD_DONE==="
