#!/bin/bash
# Host bootstrap for a2abench metal boxes (AL2023 x86 or aarch64).
# Idempotent-ish. Run under nohup.
set -x
ARCH=$(uname -m)
exec > /work-setup.log 2>&1 || true

sudo dnf install -y --skip-broken docker git python3 python3-pip jq iproute qemu-img e2fsprogs xfsprogs sysstat
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user

# instance-store NVMe: pick the largest non-root device
ROOTDEV=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)
BEST=""; BESTSZ=0
for d in /dev/nvme*n1; do
  n=$(basename "$d")
  [ "$n" = "$ROOTDEV" ] && continue
  # skip if it holds the root partition
  if lsblk -no MOUNTPOINT "$d" | grep -q '^/$'; then continue; fi
  if lsblk -nro MOUNTPOINT "$d" | grep -q '^/'; then continue; fi
  sz=$(blockdev --getsize64 "$d")
  if [ "$sz" -gt "$BESTSZ" ]; then BESTSZ=$sz; BEST=$d; fi
done
echo "PICKED_NVME=$BEST size=$BESTSZ"
sudo mkfs.xfs -f "$BEST"
sudo mkdir -p /mnt/nv
sudo mount "$BEST" /mnt/nv
sudo chown -R ec2-user:ec2-user /mnt/nv
echo "NVME_OK $BEST"
df -h /mnt/nv
lsblk -o NAME,SIZE,MODEL,ROTA "$BEST"

sudo mkdir -p /work && sudo chown ec2-user:ec2-user /work
ln -sfn /mnt/nv /work/nv

# tap+bridge networking for the guest, in the HOST netns
sudo ip link add br0 type bridge 2>/dev/null || true
sudo ip addr add 192.168.100.1/24 dev br0 2>/dev/null || true
sudo ip link set br0 up
sudo ip tuntap add dev tap0 mode tap user root 2>/dev/null || true
sudo ip link set tap0 master br0
sudo ip link set tap0 up
sudo sysctl -w net.ipv4.ip_forward=1
# DNAT so the external driver can reach the guest on the metal's private IP:5432
PRIV=$(ip -4 -o addr show scope global | grep -v br0 | awk '{print $4}' | cut -d/ -f1 | head -1)
NIC=$(ip -4 -o addr show scope global | grep -v br0 | awk '{print $2}' | head -1)
echo "PRIV=$PRIV NIC=$NIC"
sudo iptables -t nat -A PREROUTING -d "$PRIV" -p tcp --dport 5432 -j DNAT --to-destination 192.168.100.2:5432
sudo iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -j MASQUERADE
sudo iptables -A FORWARD -d 192.168.100.2 -j ACCEPT 2>/dev/null || true
sudo iptables -A FORWARD -s 192.168.100.0/24 -j ACCEPT 2>/dev/null || true
sudo iptables -t nat -L PREROUTING -n
echo NET_OK

# clone OSv (WITH the -1)
cd /work
[ -d osv ] || git clone --recurse-submodules https://github.com/gburd/osv-1.git osv
echo SETUP_DONE
