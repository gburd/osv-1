#!/bin/bash
# rss-run-build.sh -- run on the builder host. Launches the fedora:39 build container.
set -e
cd /mnt/nvme
# no /dev/kvm on m5d.4xlarge (non-metal) -> omit --device /dev/kvm; internal zfs-builder VM
# + seed step fall back to TCG (slow but functional for a one-shot bake).
KVM_ARG=""
[ -e /dev/kvm ] && KVM_ARG="--device /dev/kvm"
: > /mnt/nvme/build.log
nohup docker run --rm --privileged $KVM_ARG \
  -v /mnt/nvme/osv:/b \
  -v /mnt/nvme:/mnt/nvme \
  fedora:39 bash /mnt/nvme/cache/build-osv-pg.sh \
  > /mnt/nvme/build.log 2>&1 &
echo "BUILD_PID=$!"
