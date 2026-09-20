#!/bin/bash
# Debian host bootstrap for the leak2 metal box. Idempotent-ish. Run under nohup.
# Host only needs: docker (build+qemu run inside fedora:39 container), git, tap/bridge net.
set -x
exec > /work-setup.log 2>&1 || true

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y docker.io git python3 jq iproute2 e2fsprogs xfsprogs sysstat postgresql-client bc
sudo systemctl enable --now docker
sudo usermod -aG docker admin

# instance-store NVMe: pick the largest non-root device (nvme0/1/3/4 = 838G instance store)
ROOTDEV=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)
BEST=""; BESTSZ=0
for d in /dev/nvme*n1; do
  n=$(basename "$d")
  [ "$n" = "$ROOTDEV" ] && continue
  if lsblk -no MOUNTPOINT "$d" | grep -q '^/$'; then continue; fi
  if lsblk -nro MOUNTPOINT "$d" | grep -q '^/'; then continue; fi
  sz=$(sudo blockdev --getsize64 "$d")
  if [ "$sz" -gt "$BESTSZ" ]; then BESTSZ=$sz; BEST=$d; fi
done
echo "PICKED_NVME=$BEST size=$BESTSZ"
sudo mkfs.xfs -f "$BEST"
sudo mkdir -p /mnt/nv
sudo mount "$BEST" /mnt/nv
sudo chown -R admin:admin /mnt/nv
echo "NVME_OK $BEST"; df -h /mnt/nv

sudo mkdir -p /work && sudo chown admin:admin /work
ln -sfn /mnt/nv /work/nv

# tap+bridge networking for the guest, in the HOST netns
sudo ip link add br0 type bridge 2>/dev/null || true
sudo ip addr add 192.168.100.1/24 dev br0 2>/dev/null || true
sudo ip link set br0 up
sudo ip tuntap add dev tap0 mode tap user root 2>/dev/null || true
sudo ip link set tap0 master br0
sudo ip link set tap0 up
sudo sysctl -w net.ipv4.ip_forward=1
PRIV=$(ip -4 -o addr show scope global | grep -v br0 | awk '{print $4}' | cut -d/ -f1 | head -1)
NIC=$(ip -4 -o addr show scope global | grep -v br0 | awk '{print $2}' | head -1)
echo "PRIV=$PRIV NIC=$NIC"
sudo iptables -t nat -A PREROUTING -d "$PRIV" -p tcp --dport 5432 -j DNAT --to-destination 192.168.100.2:5432 2>/dev/null || true
sudo iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -j MASQUERADE 2>/dev/null || true
sudo iptables -A FORWARD -d 192.168.100.2 -j ACCEPT 2>/dev/null || true
sudo iptables -A FORWARD -s 192.168.100.0/24 -j ACCEPT 2>/dev/null || true
echo NET_OK

# clone OSv (WITH the -1)
cd /work
[ -d osv ] || git clone --recurse-submodules https://github.com/gburd/osv-1.git osv
echo SETUP_DONE
