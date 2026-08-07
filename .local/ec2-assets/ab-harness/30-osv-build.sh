#!/bin/bash
# 30-osv-build.sh -- build the OSv kernel + zfs-tools,pg18-fork image (fs=zfs,
# conf_zfs=openzfs, conf_fork=1) INSIDE the arena-dev build container.
# Native compile (host CPU); only the guest RUN is TCG.  Runs in tmux.
set -eu
cd /b
export PYTHONPATH=/b/scripts
# 1) submodules the hammer2 report needed force-checked-out
git submodule update --init --recursive musl_0.9.12 kbuild external/x64/acpica 2>&1 | tail -5 || true
git submodule update --init modules/open_zfs/openzfs 2>&1 | tail -3 || true
# apps: pinned commit is non-public; base apps tree = cloudius master is fine, our pg18-fork module is local.
git -c submodule."apps".update=none submodule update --init apps 2>&1 | tail -3 || true

# 2) toolchain (idempotent)
which musl-gcc >/dev/null 2>&1 || dnf install -y -q musl-gcc musl-devel readline-devel zlib-devel zlib-static libblkid-devel libuuid-devel openssl-devel >/tmp/dnf-tc.log 2>&1
python3 scripts/setup.py >/tmp/setup.log 2>&1 || tail -5 /tmp/setup.log

# 3) build kernel + combined image
echo "== building OSv kernel + zfs-tools,pg18-fork (fs=zfs conf_zfs=openzfs conf_fork=1) =="
scripts/build -j"$(nproc)" image=zfs-tools,pg18-fork fs=zfs conf_zfs=openzfs conf_fork=1 \
  2>&1 | tee /tmp/osvbuild.log | tail -30
echo "== build rc=${PIPESTATUS[0]} =="
ls -la /b/build/last/loader.elf /b/build/last/usr.img
