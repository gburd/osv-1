#!/bin/bash
# Host bootstrap for a2a-final metal box (Debian 12, m5d.metal).
# - docker (for the fedora build container only)
# - native qemu 7.2.22 (-M pc) for BOTH guests -> matched hypervisor, host-native KVM
# - /work on one instance-store NVMe (build artifacts + root qcow2)
# - /dev/nvme1n1 RESERVED raw for guest ZFS-pool passthrough (NOT formatted)
# - tap0/br0 + DNAT so the external driver reaches the guest on the metal private IP:5432
set -x
exec > /work-setup.log 2>&1 || true

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y docker.io git python3 python3-pip jq iproute2 qemu-utils \
  qemu-system-x86 e2fsprogs xfsprogs sysstat bridge-utils iptables netcat-openbsd
sudo systemctl enable --now docker
sudo usermod -aG docker admin

echo "=== qemu version (expect 7.2.x) ==="
qemu-system-x86_64 --version | head -1

# instance-store NVMe layout on m5d.metal:
#   nvme2n1 = EBS root (has partitions) -> skip
#   nvme0n1,nvme1n1,nvme3n1,nvme4n1 = 838GiB instance store
# Use nvme0n1 for /work (build + root qcow2). RESERVE nvme1n1 raw for the guest pool passthrough.
ROOTDEV=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)
echo "ROOTDEV=$ROOTDEV"
WORKDEV=""
for d in /dev/nvme0n1 /dev/nvme3n1 /dev/nvme4n1; do
  n=$(basename "$d")
  [ "$n" = "$ROOTDEV" ] && continue
  lsblk -nro MOUNTPOINT "$d" | grep -q '^/' && continue
  WORKDEV=$d; break
done
echo "WORKDEV=$WORKDEV  (POOL passthrough reserved: /dev/nvme1n1)"
sudo mkfs.xfs -f "$WORKDEV"
sudo mkdir -p /work
sudo mount "$WORKDEV" /work
sudo chown -R admin:admin /work
df -h /work

# The raw pool device stays untouched here; the guest gets it straight through.
# Make it group-accessible so qemu (run as admin via sudo) can open it.
sudo chmod 660 /dev/nvme1n1
echo "POOLDEV=/dev/nvme1n1 size=$(sudo blockdev --getsize64 /dev/nvme1n1)"

# tap+bridge in the HOST netns
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
sudo iptables -t nat -C PREROUTING -d "$PRIV" -p tcp --dport 5432 -j DNAT --to-destination 192.168.100.2:5432 2>/dev/null \
  || sudo iptables -t nat -A PREROUTING -d "$PRIV" -p tcp --dport 5432 -j DNAT --to-destination 192.168.100.2:5432
sudo iptables -t nat -C POSTROUTING -s 192.168.100.0/24 -j MASQUERADE 2>/dev/null \
  || sudo iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -j MASQUERADE
sudo iptables -C FORWARD -d 192.168.100.2 -j ACCEPT 2>/dev/null || sudo iptables -A FORWARD -d 192.168.100.2 -j ACCEPT
sudo iptables -C FORWARD -s 192.168.100.0/24 -j ACCEPT 2>/dev/null || sudo iptables -A FORWARD -s 192.168.100.0/24 -j ACCEPT
sudo iptables -t nat -L PREROUTING -n
echo NET_OK

cd /work
[ -d osv ] || git clone --recurse-submodules https://github.com/gburd/osv-1.git osv
echo SETUP_DONE
