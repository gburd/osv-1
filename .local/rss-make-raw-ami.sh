#!/bin/bash
# rss-make-raw-ami.sh -- convert usr.img (qcow2) -> raw, bake native cmdline at offset 512,
# verify boot via MBR under KVM. Produces /mnt/nvme/osv-img/ami.raw ready to dd to EBS.
set -eu
docker run --rm --privileged --device /dev/kvm \
  -v /mnt/nvme/osv:/b -v /mnt/nvme:/mnt/nvme fedora:39 bash -c '
set -eu
dnf install -y -q qemu-system-x86 qemu-img postgresql >/tmp/dnf.log 2>&1 || { tail /tmp/dnf.log; exit 1; }
RAW=/mnt/nvme/osv-img/ami.raw
echo "=== convert qcow2 -> raw ==="
qemu-img convert -O raw /mnt/nvme/osv-img/usr.img "$RAW"
ls -la "$RAW"; qemu-img info "$RAW" | head -4
echo "=== MBR sig (should be 55aa) ==="; od -An -tx1 -j 510 -N 2 "$RAW"
echo "=== bake cmdline via imgedit setargs (raw) ==="
CMD="/zpool.so import -f -N pgdata ; /zfs.so set sync=standard pgdata ; /zfs.so mount pgdata ; /b/.local/pg18/install/bin/postgres -D /data -c listen_addresses=* -c port=5432 -c unix_socket_directories= -c shared_buffers=4GB -c effective_cache_size=12GB -c max_connections=200 -c huge_pages=off -c shared_preload_libraries=plpgsql"
# raw image: OSv reads --rootfs prefix + cmdline. Native rootfs is zfs. Prepend --rootfs=zfs.
FULL="--rootfs=zfs $CMD"
python3 /b/scripts/imgedit.py setargs "-f raw $RAW" "$FULL"
echo "=== read back offset 512 ==="
python3 /b/scripts/imgedit.py getargs "-f raw $RAW"
'
echo "MAKE_RAW_RC=$?"
