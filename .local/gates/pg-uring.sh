#!/bin/bash
# PG-only: reconfigure --with-liburing (musl liburing already built in /work/liburing/install),
# rebuild, ship liburing.so into install/lib, re-bake the rofs image. Also add liburing include
# dir to the PG apps Makefile-invoked build via CFLAGS (-idirafter /usr/include for uapi headers).
set -x
exec > /work/pg-uring.log 2>&1

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
echo "WITH_LIBURING=$(grep -c USE_LIBURING src/include/pg_config.h 2>/dev/null)"
grep -i "whether to build with liburing" /tmp/pg-reconf.log
make -C src/backend generated-headers >/tmp/pg-genhdr2.log 2>&1
make -j$(nproc) LDFLAGS_EX="-pie" >/tmp/pg-make2.log 2>&1 || { echo MAKE_FAIL; tail -40 /tmp/pg-make2.log; exit 1; }
make install >/tmp/pg-install2.log 2>&1 || { echo INSTALL_FAIL; tail -20 /tmp/pg-install2.log; exit 1; }
echo PG_REBUILT_OK
# ship liburing.so into the PG install/lib so the rofs image bakes it
cp -av $URING/lib/liburing.so.2.5 /work/osv/apps/postgres18-musl/install/lib/
ln -sf liburing.so.2.5 /work/osv/apps/postgres18-musl/install/lib/liburing.so.2
ls -la /work/osv/apps/postgres18-musl/install/lib/liburing* 2>&1
echo "IO_URING_SYMS=$(nm /work/osv/apps/postgres18-musl/install/bin/postgres 2>/dev/null | grep -ic io_uring)"
ldd /work/osv/apps/postgres18-musl/install/bin/postgres 2>&1 | grep -i uring || echo "(static or via LD_LIBRARY_PATH)"
LD_LIBRARY_PATH=/work/osv/apps/postgres18-musl/install/lib /work/osv/apps/postgres18-musl/install/bin/postgres --version
'
echo "PG_URING_RC=$?"

# re-bake the rofs image
sudo docker exec bld bash -lc "cd /work/osv && ./scripts/build -j\$(nproc) conf_fork=1 conf_zfs=openzfs fs=rofs --use-openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl" 2>&1 | tail -25
echo "REBAKE_RC=$?"
echo "IMG_BYTES=$(stat -c %s /work/osv/build/last/usr.img 2>/dev/null)"
echo "MANIFEST_URING=$(grep -ic uring /work/osv/build/last/usr.manifest 2>/dev/null)"
grep -i uring /work/osv/build/last/usr.manifest 2>/dev/null | head
echo PG_URING_ALLDONE
