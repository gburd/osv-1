#!/bin/bash
# 31-mk-seed-iso.sh -- build the NoCloud cloud-init seed.iso for the Linux guest.
# Runs in the fedora qemu container (has genisoimage/xorriso via cloud-utils? we
# use a tiny FAT/iso via genisoimage). Consumes /mnt/nvme/harness/linux-user-data.
set -eu
D=/tmp/seedcfg
rm -rf "$D"; mkdir -p "$D"
cp /mnt/nvme/harness/linux-user-data "$D/user-data"
cp /mnt/nvme/harness/linux-network-config "$D/network-config"
cat > "$D/meta-data" <<EOF
instance-id: osv-abhost-linux2
local-hostname: linuxpg
EOF
which genisoimage >/dev/null 2>&1 || dnf install -y -q genisoimage >/dev/null 2>&1
genisoimage -output /mnt/nvme/seed.iso -volid cidata -joliet -rock "$D/user-data" "$D/meta-data" "$D/network-config" 2>&1 | tail -2
ls -la /mnt/nvme/seed.iso
