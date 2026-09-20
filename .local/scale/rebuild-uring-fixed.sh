#!/bin/bash
# Rebuild OSv PG18 WITH real io_uring. FIX vs the copied script: musl-gcc has no kernel
# uapi headers (linux/swab.h), so liburing itself must ALSO be built with
# -idirafter /usr/include -- the copied script only passed that to PG, so liburing never
# built and PG then failed on a missing liburing.h.
set -x
exec > /work/rebuild-uring.log 2>&1
cd /work/osv || exit 1

sudo docker exec bld bash -lc '
set -x
dnf install -y git make kernel-headers >/dev/null 2>&1 || true
cd /work
rm -rf /work/liburing
git clone --depth 1 -b liburing-2.5 https://github.com/axboe/liburing.git
cd liburing
# uapi headers: musl-gcc does not expose linux/*.h, glibc /usr/include does.
# -idirafter puts them AFTER musl so musl wins on any header it owns.
export CC="musl-gcc -idirafter /usr/include"
./configure --prefix=/work/liburing/install --cc="musl-gcc -idirafter /usr/include" 2>&1 | tail -12
CC="musl-gcc -fPIC -idirafter /usr/include" make -j$(nproc) 2>&1 | tail -12
make install 2>&1 | tail -6
echo "=== liburing musl build result ==="
ls -la /work/liburing/install/lib/ 2>&1
ls -la /work/liburing/install/include/ 2>&1 | head -5
file /work/liburing/install/lib/liburing.so* 2>&1 | head -3
'
echo "LIBURING_RC=$?"
sudo docker exec bld bash -lc 'test -f /work/liburing/install/include/liburing.h' || { echo "FATAL: liburing.h still missing"; exit 1; }

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
make -j$(nproc) LDFLAGS_EX="-pie" >/tmp/pg-make2.log 2>&1 || { echo MAKE_FAIL; grep -nE "Error 1|fatal error|undefined reference" /tmp/pg-make2.log|head -20; exit 1; }
make install >/tmp/pg-install2.log 2>&1 || { echo INSTALL_FAIL; tail -20 /tmp/pg-install2.log; exit 1; }
echo PG_REBUILT_OK
cp -av $URING/lib/liburing.so* /work/osv/apps/postgres18-musl/install/lib/ 2>&1 | tail -3
ln -sf liburing.so.2.5 /work/osv/apps/postgres18-musl/install/lib/liburing.so.2 2>/dev/null
ls -la /work/osv/apps/postgres18-musl/install/lib/liburing* 2>&1
echo "IO_URING_SYMS=$(nm /work/osv/apps/postgres18-musl/install/bin/postgres 2>/dev/null | grep -ic io_uring)"
LD_LIBRARY_PATH=/work/osv/apps/postgres18-musl/install/lib /work/osv/apps/postgres18-musl/install/bin/postgres --version
'
echo "PG_URING_RC=$?"

sudo docker exec bld bash -lc "cd /work/osv && ./scripts/build -j\$(nproc) conf_fork=1 conf_zfs=openzfs fs=rofs --use-openzfs image=open_zfs,zfs,zfs-tools,postgres18-musl" 2>&1 | tail -25
echo "REBAKE_RC=$?"
echo "IMG_BYTES=$(stat -c %s /work/osv/build/last/usr.img 2>/dev/null)"
echo "MANIFEST_URING=$(grep -ic uring /work/osv/build/last/usr.manifest 2>/dev/null)"
# snapshot the FINAL image under the tag the boot script uses
mkdir -p /work/img-fix
cp -f /work/osv/build/last/usr.img /work/img-fix/usr.img
cp -f /work/osv/build/last/loader.elf /work/img-fix/loader.elf
ls -l /work/img-fix/
echo "IMG_SHA=$(sha256sum /work/img-fix/usr.img | cut -c1-32)"
echo REBUILD_URING_DONE
