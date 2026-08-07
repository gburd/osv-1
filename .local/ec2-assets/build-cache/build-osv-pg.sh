#!/bin/bash
# build-osv-pg.sh -- BULLETPROOF reproducible build of a SERVING OSv+PostgreSQL18
# image (fs=zfs, conf_zfs=openzfs, conf_fork=1) inside a fedora:39 container.
# Runs as root inside the container; /b is the OSv checkout.
set -euo pipefail
cd /b
export PYTHONPATH=/b/scripts

echo "===== STEP 0: toolchain (fedora:39) ====="
dnf install -y -q \
  git make gcc gcc-c++ python3 python3-devel \
  musl-gcc musl-devel \
  readline-devel zlib-devel zlib-static libblkid-devel libuuid-devel openssl-devel \
  boost-devel boost-static ncurses-devel libaio-devel libedit-devel \
  libstdc++-static diffutils \
  autoconf automake libtool bison flex perl perl-FindBin perl-lib \
  wget tar xz bzip2 which file findutils gawk patch openssl \
  qemu-system-x86 qemu-img \
  >/tmp/dnf-tc.log 2>&1 || { echo "DNF TOOLCHAIN FAIL"; tail -30 /tmp/dnf-tc.log; exit 1; }
which musl-gcc gcc g++ python3 bison flex perl qemu-system-x86_64 qemu-nbd >/dev/null || { echo "MISSING TOOL"; exit 1; }
echo "toolchain ok"

echo "===== STEP 1: submodule force-checkout ====="
git config --global --add safe.directory /b || true
git submodule update --init --recursive musl_1.2.1 musl_0.9.12 kbuild external/x64/acpica 2>&1 | tail -5 || true
git submodule update --init modules/open_zfs/openzfs 2>&1 | tail -3 || true
git -c submodule."apps".update=none submodule update --init apps 2>&1 | tail -3 || true
ls modules/open_zfs/openzfs/module >/dev/null 2>&1 && echo "openzfs submodule ok" || echo "WARN openzfs submodule empty"

echo "===== STEP 2: apply pg-zfs build-infra patch (zfs-builder 4G mem) ====="
if git apply --check /mnt/nvme/fixes/pg-zfs-build-infra.patch 2>/dev/null; then
  git apply /mnt/nvme/fixes/pg-zfs-build-infra.patch && echo "build-infra patch applied"
else
  # maybe already applied
  grep -q 'zfs_builder_mem' scripts/build && echo "build-infra patch already present" || { echo "PATCH FAILED"; exit 1; }
fi

echo "===== STEP 3: clean PostgreSQL 18 source tree ====="
mkdir -p /b/.local/pg18
if [ ! -f /b/.local/pg18/src/configure ]; then
  cd /b/.local/pg18
  # official PG18 source tarball -- pristine, avoids the genbki.pl catalog-headers Error 2
  wget -q https://ftp.postgresql.org/pub/source/v18.0/postgresql-18.0.tar.bz2 -O pg18.tar.bz2 \
    || { echo "PG SRC DOWNLOAD FAILED"; exit 1; }
  rm -rf src && mkdir -p src
  tar xjf pg18.tar.bz2 -C src --strip-components=1
  rm -f pg18.tar.bz2
  cd /b
fi
test -f /b/.local/pg18/src/src/backend/main/main.c || { echo "PG SRC TREE BAD"; exit 1; }
echo "PG18 clean source at /b/.local/pg18/src"

echo "===== STEP 4: build PostgreSQL (musl-PIE) ====="
if [ -x /b/.local/pg18/install/bin/postgres ]; then
  echo "postgres already built, skipping STEP 4/4b"
else
bash /mnt/nvme/fixes/pg-build.sh 2>&1 | tail -8
test -x /b/.local/pg18/install/bin/postgres || { echo "PG POSTGRES BINARY MISSING"; exit 1; }
echo "===== STEP 4b: patch-pg (check_root+checkDataDir neuters) + rebuild backend ====="
bash /mnt/nvme/fixes/patch-pg.sh 2>&1 | tail -8
test -x /b/.local/pg18/install/bin/postgres || { echo "PG POSTGRES BINARY MISSING (post-patch)"; exit 1; }
fi
file /b/.local/pg18/install/bin/postgres

echo "===== STEP 5: recreate pg18-fork module ====="
mkdir -p /b/modules/pg18-fork
cp /mnt/nvme/fixes/pg18-fork-module.py /b/modules/pg18-fork/module.py
# module.py needs a usr.manifest sibling? OSv modules just need module.py; verify.
ls -la /b/modules/pg18-fork/
echo "pg18-fork module in place"

echo "===== STEP 6: build the combined OSv image (builds cpiod.so as part of manifest) ====="
# CRITICAL: the kconfig .config is generated ONCE and caches conf_fork. A stale
# build dir (from an earlier invocation without conf_fork=1 in the env) leaves
# CONF_fork unset -> fork.cc fails to see thread::address_space/fork_arena. Wipe
# the build tree so .config regenerates with conf_fork=1 from conf/kconfig/threads.
rm -rf /b/build/release.x64 /b/build/last 2>/dev/null || true
export conf_fork=1 conf_zfs=openzfs
# 6a) build the kernel (stage1) + tools. The pg18-fork manifest requires
#     ${OSV_BUILD_PATH}/tools/cpiod/cpiod.so, which the openzfs image path does
#     NOT build automatically -> module.py fails "cpiod.so does not exist".
#     Build cpiod.so EXPLICITLY (pulls libsolaris/libzfs prereqs) BEFORE the
#     image-assembly step. This is the banked ORDERING fix.
make mode=release arch=x64 conf_fork=1 conf_zfs=openzfs fs_type=zfs \
  build/release.x64/tools/cpiod/cpiod.so 2>&1 | tail -6
test -x /b/build/release.x64/tools/cpiod/cpiod.so || { echo "CPIOD BUILD FAILED"; exit 1; }
echo "cpiod.so built: $(ls -la /b/build/release.x64/tools/cpiod/cpiod.so)"
# 6b) now assemble the combined image (kernel cached, cpiod.so present)
scripts/build -j"$(nproc)" image=zfs-tools,pg18-fork fs=zfs conf_zfs=openzfs conf_fork=1 \
  2>&1 | tee /tmp/osvbuild.log | tail -40
BRC=${PIPESTATUS[0]}
echo "== build rc=$BRC =="
ls -la /b/build/last/loader.elf /b/build/last/usr.img 2>&1
find /b/build -name cpiod.so 2>/dev/null | head
echo "BUILD_DONE"
