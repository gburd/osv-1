#!/bin/bash
# Boot the OSv guest. Modes:
#   seed  -- create the ZFS pool ONCE on the raw NVMe-backed disk, seed_copy the baked cluster in, export
#   run   -- import-only + mount + start postgres with the mandated GUCs
# ARGS: <mode> <arch> [extra-boot-env]
set -x
MODE="$1"; ARCH="${2:-x86_64}"; shift 2
EXTRA="$*"
OSV=/work/osv
B=$OSV/build/last
POOLIMG=/mnt/nv/pgdata.raw
LOG=/work/console-$MODE-$(date +%H%M%S).log

# Guest data disk: a raw file on the XFS-on-instance-store NVMe (NOT tmpfs).
if [ "$MODE" = seed ] && [ ! -f "$POOLIMG" ]; then
  truncate -s 600G "$POOLIMG"
fi
ls -l "$POOLIMG"

# The mandated PG GUCs, passed on the postgres command line so pg_settings reports
# source='command line' (the baked conf carries stock 128MB/1GB defaults).
PGARGS="-c listen_addresses=* -c max_connections=400 -c shared_buffers=16GB \
-c effective_cache_size=32GB -c max_wal_size=64GB -c min_wal_size=2GB \
-c checkpoint_timeout=15min -c checkpoint_completion_target=0.9 -c log_checkpoints=on \
-c fsync=on -c synchronous_commit=on -c autovacuum=on -c io_method=sync \
-c shared_preload_libraries=plpgsql -c max_files_per_process=200"

if [ "$MODE" = seed ]; then
  # ORDER IS LOAD-BEARING: import/create -> zfs mount -> seed_copy -> (no postgres here)
  CMD="/zpool.so create -f -o ashift=12 -O recordsize=8k -O compression=off -O atime=off -O sync=standard -O logbias=latency -O primarycache=all -O mountpoint=/data pgdata /dev/vblk1 ; /zpool.so get ashift pgdata ; /zfs.so get recordsize,compression,atime,sync,logbias,primarycache,mountpoint pgdata ; /zfs.so list ; /usr/bin/seed_copy /data-seed /data/pg ; /zfs.so get used pgdata ; /zpool.so export pgdata"
  MEM=8G; CPUS=8
else
  CMD="/zpool.so import -f -N pgdata ; /zfs.so mount pgdata ; /zpool.so get ashift pgdata ; /zfs.so get recordsize,compression,atime,sync,logbias,primarycache pgdata ; /usr/bin/postgres -D /data/pg $PGARGS"
  MEM=64G; CPUS=32
fi

# NOTE: no --mount-fs=ramfs,/dev/null,/data (that would land the seed in RAM).
# No --norandom (PG needs a random source for cancel keys).
BOOTARGS="--rootfs=rofs --ip=eth0,192.168.100.2,255.255.255.0 --defaultgw=192.168.100.1 --nameserver=192.168.100.1 $EXTRA"

if [ "$ARCH" = aarch64 ]; then
  # aarch64 MUST use loader.img; loader.elf dies at "premain: failed to get TLS data from ELF"
  KERN="$B/loader.img"
  QEMU=qemu-system-aarch64
  MACHINE="-M virt -cpu host -enable-kvm"
else
  KERN="$B/loader.elf"
  QEMU=qemu-system-x86_64
  # -M pc: AL2023's qemu 11 only has q35 and hangs at AHCI probe; fedora:39 qemu 8.1.3 has pc
  MACHINE="-M pc -cpu host -enable-kvm"
fi
ls -l "$KERN" "$B/usr.img"

# qcow2 for the root disk; format=raw gives a misleading "Cannot find the pool label"
# vhost=off: vhost=on leaves the guest unreachable (binds the IP, never answers ARP)
set +x
CMDLINE="$BOOTARGS $CMD"
echo "BOOT CMDLINE: $CMDLINE" | tee -a "$LOG"
set -x

docker exec -d bld bash -lc "cd /work/osv && exec $QEMU $MACHINE -smp $CPUS -m $MEM -nographic -vga none \
  -kernel '$KERN' -append '$CMDLINE' \
  -drive file=$B/usr.img,if=none,id=hd0,cache=none,aio=native,format=qcow2 \
  -device virtio-blk-pci,drive=hd0,scsi=off \
  -drive file=$POOLIMG,if=none,id=hd1,cache=none,aio=native,format=raw \
  -device virtio-blk-pci,drive=hd1,scsi=off \
  -netdev tap,id=hn0,ifname=tap0,script=no,downscript=no,vhost=off \
  -device virtio-net-pci,netdev=hn0 \
  -device virtio-rng-pci \
  >> $LOG 2>&1"
sleep 3
echo "LOG=$LOG"
