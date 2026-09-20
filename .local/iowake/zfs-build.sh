#!/bin/bash
# Build OpenZFS against the RUNNING 6.12.103 kernel (kernel6.12-devel already
# installed -> /lib/modules/$(uname -r)/build exists). OpenZFS 2.3.x supports
# 6.12. No reboot needed. Loads the module, ready for the Linux ZFS arm.
set -x
exec > /home/ec2-user/zfs-build.log 2>&1
echo "=== START $(date) ==="

# deps (kernel6.12-devel already present)
sudo dnf install -y gcc make autoconf automake libtool rpm-build \
    libtirpc-devel libblkid-devel libuuid-devel openssl-devel \
    zlib-devel libaio-devel libattr-devel elfutils-libelf-devel python3 \
    python3-devel libffi-devel git ncompress systemd-devel 2>&1 | tail -6

cd /home/ec2-user
ZVER=2.3.4
rm -rf zfs-$ZVER zfs-$ZVER.tar.gz
curl -fsSL -o zfs-$ZVER.tar.gz https://github.com/openzfs/zfs/releases/download/zfs-$ZVER/zfs-$ZVER.tar.gz
tar xf zfs-$ZVER.tar.gz
cd zfs-$ZVER
KVER=$(uname -r)
./configure --with-linux=/lib/modules/$KVER/build --with-linux-obj=/lib/modules/$KVER/build 2>&1 | tail -12
echo "CONFIGURE_RC=${PIPESTATUS[0]}"
make -j$(nproc) 2>&1 | tail -6
echo "MAKE_RC=${PIPESTATUS[0]}"
sudo make install 2>&1 | tail -6
echo "MAKE_INSTALL_RC=${PIPESTATUS[0]}"
sudo depmod -a $KVER 2>&1 | tail -3
sudo modprobe zfs 2>&1 | tail -3
echo "MODPROBE_RC=$?"
echo "=== zfs loaded? ==="
lsmod | grep zfs 2>&1
sudo /sbin/zpool version 2>&1 || /usr/local/sbin/zpool version 2>&1
echo "=== END $(date) ==="
echo ZFS_BUILD_DONE
