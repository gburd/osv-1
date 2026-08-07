#!/bin/bash
# Build stock musl PostgreSQL 18.4 as an OSv PIE, in the build container.
set -e
SRC=/b/.local/pg18/src
PREFIX=/b/.local/pg18/install
BUILD=/b/.local/pg18/obj
rm -rf "$BUILD" "$PREFIX"
mkdir -p "$BUILD"
cd "$BUILD"

export CC=musl-gcc
CFLAGS='-O2 -g -fPIC -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -DWAIT_USE_SELF_PIPE -idirafter /usr/include'

"$SRC/configure" \
  --prefix="$PREFIX" \
  --without-icu --without-zlib --without-readline \
  --without-libxml --without-lz4 --without-zstd \
  CFLAGS="$CFLAGS" 2>&1 | tail -3

make -j48 LDFLAGS_EX='-pie' 2>&1 | tail -4
make install 2>&1 | tail -3
echo "=== built postgres ==="
file "$PREFIX/bin/postgres"
ls "$PREFIX/bin/"
