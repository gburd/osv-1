set -x
URING=/work/liburing/install
export PKG_CONFIG_PATH=$URING/lib/pkgconfig
# bypass pkg-config with explicit CFLAGS/LIBS (configure honours these directly)
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
echo "=== configure liburing result ==="
grep -iE 'liburing|with_liburing|USE_LIBURING' /tmp/pg-reconf.log | head
grep -iE 'USE_LIBURING' src/include/pg_config.h 2>/dev/null || grep -iE 'USE_LIBURING' /work/osv/apps/postgres18-musl/build/src/include/pg_config.h 2>/dev/null
make -C src/backend generated-headers >/tmp/pg-genhdr2.log 2>&1
make -j$(nproc) LDFLAGS_EX='-pie' >/tmp/pg-make2.log 2>&1 || { echo MAKE_FAIL; tail -30 /tmp/pg-make2.log; exit 1; }
make install >/tmp/pg-install2.log 2>&1 || { echo INSTALL_FAIL; tail -20 /tmp/pg-install2.log; exit 1; }
echo PG_REBUILT_WITH_URING
# ship the musl liburing.so into the PG install/lib so the OSv image bakes it
cp -av $URING/lib/liburing.so.2.5 /work/osv/apps/postgres18-musl/install/lib/
ln -sf liburing.so.2.5 /work/osv/apps/postgres18-musl/install/lib/liburing.so.2
ls -la /work/osv/apps/postgres18-musl/install/lib/liburing*
echo "=== rebuilt postgres uring link ==="
grep -c USE_LIBURING /work/osv/apps/postgres18-musl/build/src/include/pg_config.h 2>/dev/null
LD_LIBRARY_PATH=/work/osv/apps/postgres18-musl/install/lib /work/osv/apps/postgres18-musl/install/bin/postgres --version
echo PG_URING_BUILD_DONE
