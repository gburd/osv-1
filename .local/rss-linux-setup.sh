#!/bin/bash
# rss-linux-setup.sh -- on the Linux-native box (AL2023). Install PG18 + OpenZFS, create the
# SAME ZFS layout (ashift=12 lz4 atime=off recordsize=8k, pool 'pgdata' -m /data) on the 40G
# EBS data disk, initdb, configure PG with the SAME serve knobs, start. sync=standard.
set -eu
sudo dnf install -y -q gcc make kernel-devel-$(uname -r) 2>&1 | tail -1 || true
# OpenZFS via the zfs-release repo (kmod for AL2023 kernel). Fallback: DKMS.
sudo dnf install -y -q https://zfsonlinux.org/epel/zfs-release-2-3$(rpm --eval "%{dist}").noarch.rpm 2>/dev/null || \
  sudo dnf install -y -q https://zfsonlinux.org/epel/zfs-release.el9_$(rpm --eval "%{?dist}").noarch.rpm 2>/dev/null || true
echo "=== try zfs install ==="
sudo dnf install -y -q zfs 2>&1 | tail -3 || echo ZFS_DNF_MAYBE_DKMS
sudo modprobe zfs 2>&1 && echo ZFS_MODULE_OK || echo ZFS_MODULE_FAIL
zfs version 2>&1 | head -2 || true
