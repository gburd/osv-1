#!/bin/bash
# Build stock musl PostgreSQL 18.4 as an OSv PIE, in the arena-dev container.
set -e
SRC=/b/.local/pg18/src
PREFIX=/b/.local/pg18/install
BUILD=/b/.local/pg18/obj
rm -rf "$BUILD" "$PREFIX"
mkdir -p "$BUILD"
cd "$BUILD"

export CC=musl-gcc
# -DWAIT_USE_SELF_PIPE: use self-pipe instead of signalfd (OSv signalfd is a stub)
CFLAGS='-O2 -g -fPIC -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -DWAIT_USE_SELF_PIPE -idirafter /usr/include'

"$SRC/configure" \
  --prefix="$PREFIX" \
  --without-icu --without-zlib --without-readline \
  --without-libxml --without-lz4 --without-zstd \
  CFLAGS="$CFLAGS" 2>&1 | tail -5

# Build the postgres server binary as a PIE.
make -j"$(nproc)" LDFLAGS_EX='-pie' 2>&1 | tail -8
make install 2>&1 | tail -4
echo "=== built postgres ==="
file "$PREFIX/bin/postgres"
readelf -h "$PREFIX/bin/postgres" | grep -E 'Type|interpreter' || true
readelf -l "$PREFIX/bin/postgres" | grep -i interp || true
