#!/bin/bash
# BUILDER host setup: docker + git + qemu-img on AL2023, /work on the local NVMe.
set -x
sudo dnf install -y docker git qemu-img python3-pip jq 2>&1 | tail -3
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
# /work on local NVMe (fast, big). nvme0n1 is the 1.7T instance store on c6id.8xlarge.
D=$(lsblk -dn -o NAME,SIZE,TYPE | awk '$3=="disk" && $2 ~ /T$/ {print $1; exit}')
echo "LOCAL_NVME=$D"
sudo mkfs.xfs -f /dev/$D 2>&1 | tail -2
sudo mkdir -p /work && sudo mount /dev/$D /work && sudo chown ec2-user:ec2-user /work
df -h /work
echo HOSTSETUP_DONE
