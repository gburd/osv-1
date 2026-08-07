#!/bin/bash
# rss-bake-cmdline.sh -- bake the native OSv serve cmdline at offset 512 into a copy of usr.img.
# DEFAULT mmap (no shared_memory_type=sysv), task-specified PG config.
set -e
cd /mnt/nvme/osv
AMI_IMG=/mnt/nvme/osv-img/ami-usr.img
cp /mnt/nvme/osv-img/usr.img "$AMI_IMG"
# serve cmdline: import pgdata by name (works on NVMe or EBS), mount, run postgres.
# DEFAULT mmap: NO shared_memory_type=sysv. trust auth (seed pg_hba 0.0.0.0/0 trust).
CMD='/zpool.so import -f -N pgdata ; /zfs.so set sync=standard pgdata ; /zfs.so mount pgdata ; /b/.local/pg18/install/bin/postgres -D /data -c listen_addresses=* -c port=5432 -c unix_socket_directories= -c shared_buffers=4GB -c effective_cache_size=12GB -c max_connections=200 -c huge_pages=off -c shared_preload_libraries=plpgsql'
# usr.img is RAW -> write cmdline directly at offset 512 (imgedit's NBD path needs qemu-nbd).
# OSv reads a NUL-terminated string at offset 512 (max 1024 bytes).
printf '%s\0' "$CMD" | dd of="$AMI_IMG" bs=1 seek=512 conv=notrunc 2>/dev/null
echo "=== baked cmdline (offset 512) ==="
dd if="$AMI_IMG" bs=1 skip=512 count=400 2>/dev/null | tr -d '\0'; echo
echo "AMI_IMG=$AMI_IMG size=$(stat -c %s "$AMI_IMG")"
