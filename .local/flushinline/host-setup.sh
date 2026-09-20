#!/bin/bash
# Debian host bootstrap for the flushinline metal box.
# - native qemu (Debian 12 -> qemu 7.2) for BOOTING OSv (-M pc)
# - docker + fedora:39 for BUILDING OSv (its toolchain), NOT for booting
# Idempotent-ish. Run under nohup.
set -x
exec > /tmp/host-setup.log 2>&1 || true

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y qemu-system-x86 qemu-utils docker.io git python3 python3-pip jq \
  iproute2 e2fsprogs xfsprogs sysstat bc net-tools iptables
sudo systemctl enable --now docker
sudo usermod -aG docker admin

echo "=== qemu version (native boot path) ==="
qemu-system-x86_64 --version | head -1

# instance-store NVMe for the guest data disk: pick a raw instance-store dev (NOT root EBS).
# On m5d.metal the instance-store devices are the "NVMe Instance Storage" ones.
ROOTDEV=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)
DATADISK=""
for d in /dev/nvme0n1 /dev/nvme1n1 /dev/nvme3n1 /dev/nvme4n1; do
  n=$(basename "$d")
  [ "$n" = "$ROOTDEV" ] && continue
  if lsblk -nro MOUNTPOINT "$d" | grep -q '^/'; then continue; fi
  # instance-store model string
  if lsblk -no MODEL "$d" | grep -qi 'Instance Storage'; then DATADISK=$d; break; fi
done
echo "DATADISK=$DATADISK"
# Build workspace on a big instance-store xfs (separate from the data disk).
WORKDISK=""
for d in /dev/nvme0n1 /dev/nvme1n1 /dev/nvme3n1 /dev/nvme4n1; do
  [ "$d" = "$DATADISK" ] && continue
  if lsblk -no MODEL "$d" | grep -qi 'Instance Storage'; then WORKDISK=$d; break; fi
done
echo "WORKDISK=$WORKDISK"
sudo mkfs.xfs -f "$WORKDISK"
sudo mkdir -p /work && sudo mount "$WORKDISK" /work && sudo chown -R admin:admin /work
df -h /work

# record the data disk path for the bench scripts
echo "$DATADISK" | sudo tee /work/DATADISK
echo "NVME_OK data=$DATADISK work=$WORKDISK"

# tap+bridge for the guest (host netns) — needed for STEP C (driver reaches PG)
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

# clone OSv (fork, with the -1)
cd /work
[ -d osv ] || git clone --recurse-submodules https://github.com/gburd/osv-1.git osv
echo SETUP_DONE
