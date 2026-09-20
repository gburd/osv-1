#!/bin/bash
# Rebuild the OSv PG18 image WITH real io_uring: build musl liburing 2.5 from source, reconfigure
# PG --with-liburing pointing at it, ship liburing.so into install/lib, re-bake the rofs image.
# Correct for THIS tree layout: PG build dir is .../postgres18-musl/build directly (no postgres* subdir).
set -x
exec > /work/rebuild-uring.log 2>&1
cd /work/osv || exit 1

# 1) musl liburing 2.5 from source, inside the build container
sudo docker exec bld bash -lc '
set -x
dnf install -y git make >/dev/null 2>&1 || true
cd /work
[ -d liburing ] || git clone --depth 1 -b liburing-2.5 https://github.com/axboe/liburing.git
cd liburing
make clean 2>/dev/null || true
CC=musl-gcc ./configure --prefix=/work/liburing/install 2>&1 | tail -10
CC="musl-gcc -fPIC" make -j$(nproc) 2>&1 | tail -15
make install 2>&1 | tail -8
echo "=== liburing musl build ==="
ls -la /work/liburing/install/lib/ 2>&1
file /work/liburing/install/lib/liburing.so* 2>&1 | head
'
echo "LIBURING_MUSL_RC=$?"

# 2) reconfigure + rebuild PG with --with-liburing (build dir = .../build)
sudo docker exec bld bash -lc '
set -x
URING=/work/liburing/install
export PKG_CONFIG_PATH=$URING/lib/pkgconfig
export LIBURING_CFLAGS="-I$URING/include"
export LIBURING_LIBS="-L$URING/lib -luring"
cd /work/osv/apps/postgres18-musl/build || { echo NO_BUILD_DIR; exit 1; }
make distclean >/dev/null 2>&1 || true
CFLAGS="-O2 -g -fPIC -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -DWAIT_USE_SELF_PIPE -idirafter /usr/include -I$URING/include"
LDFLAGS="-L$URING/lib"
../src/configure --prefix=/work/osv/apps/postgres18-musl/install \
  --without-icu --without-zlib --without-readline \
  --without-libxml --without-lz4 --without-zstd \
  --with-liburing \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
  LIBURING_CFLAGS="$LIBURING_CFLAGS" LIBURING_LIBS="$LIBURING_LIBS" >/tmp/pg-reconf.log 2>&1 || { echo CONFIGURE_FAIL; tail -30 /tmp/pg-reconf.log; exit 1; }
echo "=== with_liburing result ==="
grep -iE "whether to build with liburing|with_liburing=" /tmp/pg-reconf.log config.log 2>/dev/null | head
grep -c USE_LIBURING src/include/pg_config.h 2>/dev/null
make -C src/backend generated-headers >/tmp/pg-genhdr2.log 2>&1
make -j$(nproc) LDFLAGS_EX="-pie" >/tmp/pg-make2.log 2>&1 || { echo MAKE_FAIL; tail -30 /tmp/pg-make2.log; exit 1; }
make install >/tmp/pg-install2.log 2>&1 || { echo INSTALL_FAIL; tail -20 /tmp/pg-install2.log; exit 1; }
echo PG_REBUILT
# ship the musl liburing.so into install/lib so the image bakes it
cp -av $URING/lib/liburing.so* /work/osv/apps/postgres18-musl/install/lib/ 2>&1 | tail
ln -sf liburing.so.2.5 /work/osv/apps/postgres18-musl/install/lib/liburing.so.2 2>/dev/null || true
ls -la /work/osv/apps/postgres18-musl/install/lib/liburing* 2>&1
echo "=== postgres now links uring? ==="
ldd /work/osv/apps/postgres18-musl/install/bin/postgres 2>&1 | grep -i uring || echo no_dynamic_uring
nm /work/osv/apps/postgres18-musl/install/bin/postgres 2>/dev/null | grep -ic io_uring
LD_LIBRARY_PATH=/work/osv/apps/postgres18-musl/install/lib /work/osv/apps/postgres18-musl/install/bin/postgres --version
'
echo "PG_URING_REBUILD_RC=$?"

# 3) re-bake the rofs image (PG + liburing.so now in install/)
sudo docker exec bld bash -lc "cd /work/osv && ./scripts/build -j\$(nproc) conf_fork=1 conf_zfs=openzfs fs=rofs --use-openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl" 2>&1 | tail -30
echo "REBAKE_RC=$?"
echo "=== new image ==="; du -m /work/osv/build/last/usr.img 2>/dev/null; stat -c %s /work/osv/build/last/usr.img 2>/dev/null
echo "=== liburing in manifest? ==="; grep -ic uring /work/osv/build/last/usr.manifest 2>/dev/null
echo REBUILD_URING_DONE
