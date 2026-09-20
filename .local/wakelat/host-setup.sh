#!/bin/bash
# Provision the m5d.metal host: qemu (host-native, for -M pc OSv boot), docker
# (fedora build container), NVMe scratch pool for the OSv image + ZFS bench.
set -x
exec > /home/admin/host-setup.log 2>&1
echo "=== HOST SETUP START $(date) ==="

sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  qemu-system-x86 qemu-utils docker.io git build-essential \
  python3 python3-pip curl wget xfsprogs jq bc sysstat 2>&1 | tail -5

sudo systemctl enable --now docker 2>&1 | tail -2
sudo usermod -aG docker admin 2>&1

echo "=== qemu version ==="
qemu-system-x86_64 --version | head -1
echo "=== kvm halt_poll_ns ==="
cat /sys/module/kvm/parameters/halt_poll_ns

# Scratch on the four instance NVMes (838G each). Use nvme0n1 for build/image
# workspace (XFS), and nvme1n1 raw-passthrough to the OSv guest for ZFS (matches
# a2a: /dev/nvme1n1 straight through, cache=none aio=native format=raw).
echo "=== NVMe layout ==="
lsblk -dpno NAME,SIZE | grep -E 'nvme[0134]n1'

# Build/workspace disk: nvme0n1 -> /scratch (XFS)
if ! mountpoint -q /scratch; then
  sudo mkfs.xfs -f /dev/nvme0n1 2>&1 | tail -2
  sudo mkdir -p /scratch
  sudo mount /dev/nvme0n1 /scratch
  sudo chown admin:admin /scratch
fi
df -h /scratch

# nvme1n1 stays RAW for guest ZFS passthrough (do NOT format).
echo "=== nvme1n1 reserved raw for guest ZFS passthrough ==="
sudo blkdiscard /dev/nvme1n1 2>&1 | tail -1 || echo "blkdiscard skipped"

echo "HOST_SETUP_DONE $(date)"
