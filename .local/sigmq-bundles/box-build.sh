#!/bin/bash
# Run the fedora:39 build container for the OSv+PG image. $1 = git ref to build.
# Produces /mnt/nvme/osv/build/last/{loader.elf,usr.img}, then copies to /mnt/nvme/img-<tag>/
set -e
REF="${1:-861be4908}"
TAG="${2:-unfixed}"
cd /mnt/nvme/osv
git checkout -q "$REF" 2>&1 | tail -1 || { echo "CHECKOUT FAIL $REF"; exit 1; }
echo "=== building tag=$TAG ref=$REF HEAD=$(git rev-parse --short HEAD) ==="

sudo docker run --rm --privileged --device /dev/kvm \
  -v /mnt/nvme/osv:/b -v /mnt/nvme:/mnt/nvme \
  fedora:39 bash /mnt/nvme/build-osv-pg.sh 2>&1 | tail -60

RC=${PIPESTATUS[0]}
if [ -f /mnt/nvme/osv/build/last/loader.elf ] && [ -f /mnt/nvme/osv/build/last/usr.img ]; then
  mkdir -p "/mnt/nvme/img-$TAG"
  cp /mnt/nvme/osv/build/last/loader.elf "/mnt/nvme/img-$TAG/"
  cp /mnt/nvme/osv/build/last/usr.img "/mnt/nvme/img-$TAG/"
  ls -la "/mnt/nvme/img-$TAG/"
  echo "IMG_SAVED tag=$TAG"
else
  echo "BUILD_FAIL tag=$TAG rc=$RC"
  exit 1
fi
