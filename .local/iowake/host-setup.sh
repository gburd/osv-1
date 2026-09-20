#!/bin/bash
# Host setup for the iowake latency-decomposition run.
# Installs docker (OSv build container) + zfs (Linux arm) + gcc.
set -x
exec > /home/ec2-user/host-setup.log 2>&1
echo "=== START $(date) ==="

# Docker for the fedora:39 OSv build container
sudo dnf install -y docker git gcc make 2>&1 | tail -5
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user

# ZFS on the host (Linux arm). AL2023 uses kmod-zfs from the OpenZFS repo.
# Try the zfs package straight; if not, build the DKMS module.
sudo dnf install -y https://zfsonlinux.org/fedora/zfs-release-2-4$(rpm --eval "%{dist}").noarch.rpm 2>&1 | tail -3 || true
# AL2023 dist tag may not match; fall back to the el9 repo which is source-compatible enough for DKMS.
if ! rpm -q zfs-release >/dev/null 2>&1; then
  sudo dnf install -y https://zfsonlinux.org/epel/zfs-release-2-3.el9.noarch.rpm 2>&1 | tail -3 || true
fi
# kernel headers for DKMS
sudo dnf install -y kernel-devel-$(uname -r) kernel-headers-$(uname -r) dkms 2>&1 | tail -5

echo "=== docker version ==="; sudo docker --version
echo "=== zfs-release ==="; rpm -q zfs-release 2>&1
echo "=== END $(date) ==="
echo HOST_SETUP_DONE
