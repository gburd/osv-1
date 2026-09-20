#!/bin/bash
# Install the amazonlinux 6.1 kernel + OpenZFS DKMS so the Linux arm has real
# ZFS-on-NVMe. 6.1 is LTS and fully supported by OpenZFS 2.2.x. We must boot
# into 6.1 (the AMI default 6.12.103 has no kernel-devel in the repo).
set -x
exec > /home/ec2-user/zfs-setup.log 2>&1
echo "=== START $(date) ==="

# 1. Install the 6.1 kernel + its devel/headers (matched version in repo)
sudo dnf install -y kernel-6.1.182-227.379.amzn2023 kernel-devel-6.1.182-227.379.amzn2023 \
    kernel-headers-6.1.182-227.379.amzn2023 2>&1 | tail -8
echo "KERNEL_INSTALL_RC=${PIPESTATUS[0]}"

# 2. Build deps + DKMS for OpenZFS
sudo dnf install -y dkms gcc make autoconf automake libtool rpm-build \
    libtirpc-devel libblkid-devel libuuid-devel libudev-devel openssl-devel \
    zlib-devel libaio-devel libattr-devel elfutils-libelf-devel python3 \
    python3-devel python3-setuptools python3-cffi libffi-devel git ncompress 2>&1 | tail -8

# 3. Fetch OpenZFS 2.2.7 (supports 6.1 LTS cleanly) and build against 6.1 kernel
cd /home/ec2-user
ZVER=2.2.7
curl -fsSL -o zfs-$ZVER.tar.gz https://github.com/openzfs/zfs/releases/download/zfs-$ZVER/zfs-$ZVER.tar.gz
tar xf zfs-$ZVER.tar.gz
cd zfs-$ZVER
KVER=6.1.182-227.379.amzn2023.x86_64
./configure --with-linux=/usr/src/kernels/$KVER --with-linux-obj=/usr/src/kernels/$KVER 2>&1 | tail -15
echo "CONFIGURE_RC=${PIPESTATUS[0]}"
make -j$(nproc) 2>&1 | tail -8
echo "MAKE_RC=${PIPESTATUS[0]}"
sudo make install 2>&1 | tail -8
echo "MAKE_INSTALL_RC=${PIPESTATUS[0]}"
sudo depmod -a $KVER 2>&1 | tail -3

# 4. Set 6.1 as the default boot kernel
sudo grubby --set-default /boot/vmlinuz-$KVER 2>&1
echo "DEFAULT_KERNEL=$(sudo grubby --default-kernel)"

echo "=== END $(date) ==="
echo ZFS_SETUP_DONE
