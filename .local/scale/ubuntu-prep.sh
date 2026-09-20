#!/bin/bash
# Prepare the Ubuntu 24.04 (glibc) Linux guest for the matched Linux arm (Option B).
# Host-native qemu 7.2.22 (-M pc), RAW /dev/nvme1n1 passthrough as vdb, static IP 192.168.100.2.
# Ubuntu ships ZFS (zfsutils-linux) + io_uring PG readily. libc=glibc is the one documented caveat.
set -x
exec > /work/ubuntu-prep.log 2>&1
cd /work
UBU=/work/ubuntu.qcow2
SEED=/work/useed.iso

if [ ! -f /work/ubuntu-base.img ]; then
  curl -fL -o /work/ubuntu-base.img https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
fi
cp -f /work/ubuntu-base.img "$UBU"
qemu-img resize "$UBU" 40G
qemu-img info "$UBU" | grep -E 'format|virtual'

PUBKEY=$(cat /work/osv-hotdog.pub)
mkdir -p /work/useedcfg
cat > /work/useedcfg/meta-data <<EOF
instance-id: ubuntu-arm
local-hostname: ubuntuguest
EOF
cat > /work/useedcfg/network-config <<EOF
version: 2
ethernets:
  enp0s2:
    match:
      name: "en*"
    addresses:
      - 192.168.100.2/24
    routes:
      - to: default
        via: 192.168.100.1
    nameservers:
      addresses: [192.168.100.1, 8.8.8.8]
EOF
cat > /work/useedcfg/user-data <<EOF
#cloud-config
disable_root: false
ssh_pwauth: true
ssh_authorized_keys:
  - $PUBKEY
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - $PUBKEY
bootcmd:
  - [ sh, -c, "ip addr add 192.168.100.2/24 dev enp0s2 2>/dev/null || ip addr add 192.168.100.2/24 dev ens2 2>/dev/null || true" ]
runcmd:
  - [ sh, -c, "for i in \$(ls /sys/class/net | grep -E '^en'); do ip addr add 192.168.100.2/24 dev \$i 2>/dev/null; ip link set \$i up; done; ip route add default via 192.168.100.1 2>/dev/null || true" ]
EOF
genisoimage -output "$SEED" -volid cidata -joliet -rock \
  /work/useedcfg/user-data /work/useedcfg/meta-data /work/useedcfg/network-config 2>&1 | tail -2
ls -la "$SEED" "$UBU"
echo UBUNTU_PREP_DONE
