#!/bin/bash
# rss-builder-setup.sh -- setup on c5n.metal builder (KVM). No local NVMe; use root disk.
set -e
sudo mkdir -p /mnt/nvme
sudo chown ec2-user:ec2-user /mnt/nvme
df -h /mnt/nvme
sudo dnf install -y -q docker git rsync 2>&1 | tail -2
sudo systemctl enable --now docker 2>&1 | tail -1
sudo usermod -aG docker ec2-user
docker --version
mkdir -p /mnt/nvme/fixes /mnt/nvme/harness /mnt/nvme/cache
echo SETUP_DONE
