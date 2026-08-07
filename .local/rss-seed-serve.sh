#!/bin/bash
# rss-seed-serve.sh -- on builder host: run kvm-seed-serve.sh in a fedora qemu+kvm container.
set -e
: > /mnt/nvme/seed-serve.log
docker run --rm --privileged --device /dev/kvm \
  -v /mnt/nvme/osv:/b \
  -v /mnt/nvme:/mnt/nvme \
  fedora:39 bash -c '
    dnf install -y -q qemu-system-x86 qemu-img postgresql python3 iproute >/tmp/dnf.log 2>&1 || { tail -20 /tmp/dnf.log; exit 1; }
    bash /mnt/nvme/cache/kvm-seed-serve.sh
  ' > /mnt/nvme/seed-serve.log 2>&1
echo "SEED_SERVE_RC=$?"
tail -40 /mnt/nvme/seed-serve.log
