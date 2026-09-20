#!/bin/bash
# Prepare the Alpine (musl) Linux guest for the matched Linux arm.
# Host-native qemu 7.2.22 (-M pc), RAW /dev/nvme1n1 passthrough as vdb, static IP 192.168.100.2.
set -x
exec > /work/linux-prep.log 2>&1
cd /work
ALPINE=/work/alpine.qcow2
SEED=/work/seed.iso

# always start from a fresh pristine image (clean cloud-init state)
if [ ! -f /work/alpine-fresh.qcow2 ]; then
  curl -fL -o /work/alpine-fresh.qcow2 https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/cloud/nocloud_alpine-3.21.4-x86_64-bios-cloudinit-r0.qcow2
  qemu-img resize /work/alpine-fresh.qcow2 30G
fi
cp -f /work/alpine-fresh.qcow2 "$ALPINE"
ls -la "$ALPINE"

PUBKEY=$(cat /work/osv-lava.pub)
mkdir -p /work/seedcfg
cat > /work/seedcfg/meta-data <<EOF
instance-id: linux-arm-v2
local-hostname: linuxguest
EOF

cat > /work/seedcfg/network-config <<EOF
version: 2
ethernets:
  eth0:
    addresses:
      - 192.168.100.2/24
    gateway4: 192.168.100.1
EOF

cat > /work/seedcfg/user-data <<EOF
#cloud-config
disable_root: false
ssh_pwauth: true
ssh_authorized_keys:
  - $PUBKEY
write_files:
  - path: /etc/network/interfaces
    content: |
      auto lo
      iface lo inet loopback
      auto eth0
      iface eth0 inet static
        address 192.168.100.2
        netmask 255.255.255.0
        gateway 192.168.100.1
  - path: /root/.ssh/authorized_keys
    permissions: '0600'
    content: |
      $PUBKEY
bootcmd:
  - mkdir -p /root/.ssh
  - echo '$PUBKEY' > /root/.ssh/authorized_keys
  - chmod 700 /root/.ssh
  - chmod 600 /root/.ssh/authorized_keys
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - ip addr add 192.168.100.2/24 dev eth0 2>/dev/null || true
  - ip link set eth0 up
  - ip route add default via 192.168.100.1 2>/dev/null || true
runcmd:
  - rc-service sshd restart 2>/dev/null || service sshd restart 2>/dev/null || true
EOF

genisoimage -output "$SEED" -volid cidata -joliet -rock \
  /work/seedcfg/user-data /work/seedcfg/meta-data /work/seedcfg/network-config 2>&1 | tail -3
ls -la "$SEED"
echo LINUX_PREP_DONE
