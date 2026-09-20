#!/bin/bash
# Rebuild the OSv PG18 image WITH io_uring support:
#  1. build liburing from source with musl-gcc (ABI-match the musl PG),
#  2. reconfigure/rebuild PG with --with-liburing,
#  3. ship liburing.so into install/lib so the image carries it,
#  4. re-bake the image.
set -x
exec > /work/rebuild-uring.log 2>&1
cd /work/osv || exit 1

# liburing source + musl build inside the container
docker exec bld bash -lc '
set -x
dnf install -y git make || true
cd /work
if [ ! -d liburing ]; then git clone --depth 1 -b liburing-2.5 https://github.com/axboe/liburing.git; fi
cd liburing
make clean 2>/dev/null || true
# build with musl-gcc, PIC, no libc extras liburing does not need
CC=musl-gcc ./configure --prefix=/work/liburing/install 2>&1 | tail -20
CC="musl-gcc -fPIC" make -j$(nproc) 2>&1 | tail -25
make install 2>&1 | tail -10
echo "=== liburing musl build ==="
ls -la /work/liburing/install/lib/ 2>&1
file /work/liburing/install/lib/liburing.so* 2>&1 | head
'
echo "LIBURING_MUSL_RC=$?"

PGSRC=$(ls -d /work/osv/apps/postgres18-musl/build/postgres* 2>/dev/null | head -1)
echo "PGSRC=$PGSRC"

# Reconfigure + rebuild PG with --with-liburing, pointing at the musl liburing.
docker exec bld bash -lc "
set -x
URING=/work/liburing/install
export PKG_CONFIG_PATH=\$URING/lib/pkgconfig
cd $PGSRC || { echo NO_PGSRC; exit 1; }
make distclean 2>/dev/null || true
CFLAGS='-O2 -g -fPIC -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -DWAIT_USE_SELF_PIPE -idirafter /usr/include -I\$URING/include'
LDFLAGS=\"-L\$URING/lib\"
./configure --prefix=/work/osv/apps/postgres18-musl/install \
  --without-icu --without-zlib --without-readline \
  --without-libxml --without-lz4 --without-zstd \
  --with-liburing \
  CFLAGS=\"\$CFLAGS\" LDFLAGS=\"\$LDFLAGS\" LIBS='-luring' >/tmp/pg-reconf.log 2>&1 || { echo CONFIGURE_FAIL; tail -30 /tmp/pg-reconf.log; exit 1; }
grep -iE 'liburing|with_liburing|USE_LIBURING' /tmp/pg-reconf.log | head
grep -iE 'with_liburing|USE_LIBURING' src/include/pg_config.h config.log 2>/dev/null | head
make -C src/backend generated-headers >/tmp/pg-genhdr2.log 2>&1
make -j\$(nproc) LDFLAGS_EX='-pie' >/tmp/pg-make2.log 2>&1 || { echo MAKE_FAIL; tail -30 /tmp/pg-make2.log; exit 1; }
make install >/tmp/pg-install2.log 2>&1 || { echo INSTALL_FAIL; tail -20 /tmp/pg-install2.log; exit 1; }
echo PG_REBUILT
# ship liburing.so into the PG install/lib so the OSv manifest bakes it
cp -av \$URING/lib/liburing.so* /work/osv/apps/postgres18-musl/install/lib/ 2>&1 | tail
ls -la /work/osv/apps/postgres18-musl/install/lib/liburing* 2>&1
# confirm the rebuilt postgres links liburing
ldd /work/osv/apps/postgres18-musl/install/bin/postgres 2>&1 | grep -i uring || echo 'no dynamic uring (may be static)'
LD_LIBRARY_PATH=/work/osv/apps/postgres18-musl/install/lib /work/osv/apps/postgres18-musl/install/bin/postgres --version
"
echo "PG_URING_REBUILD_RC=$?"

# Re-bake the image (PG binary + liburing.so now in install/)
NPROC=\$(nproc)
docker exec bld bash -lc "cd /work/osv && ./scripts/build -j$(nproc) conf_fork=1 conf_zfs=openzfs fs=rofs --use-openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl" 2>&1 | tail -40
echo "REBAKE_RC=$?"
echo "=== new image ==="; du -m /work/osv/build/last/usr.img 2>/dev/null
echo "=== liburing in manifest? ==="; grep -c uring /work/osv/build/last/usr.manifest 2>/dev/null
echo REBUILD_URING_DONE
