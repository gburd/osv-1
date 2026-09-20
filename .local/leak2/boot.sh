#!/bin/bash
# Boot the OSv guest (leak2). Modes: seed (create+seed ZFS pool), run (import+start PG).
# ARGS: <mode> [extra-boot-env]
set -x
MODE="$1"; shift 2>/dev/null
EXTRA="$*"
OSV=/work/osv
B=$OSV/build/last
POOLIMG=/mnt/nv/pgdata.raw
LOG=/work/console-$MODE-$(date +%H%M%S).log

if [ "$MODE" = seed ] && [ ! -f "$POOLIMG" ]; then
  truncate -s 200G "$POOLIMG"
fi
ls -l "$POOLIMG"

PGARGS="-c listen_addresses=* -c max_connections=400 -c shared_buffers=8GB \
-c effective_cache_size=16GB -c max_wal_size=32GB -c min_wal_size=2GB \
-c checkpoint_timeout=15min -c checkpoint_completion_target=0.9 -c log_checkpoints=on \
-c fsync=on -c synchronous_commit=on -c autovacuum=on -c io_method=sync \
-c shared_preload_libraries=plpgsql -c max_files_per_process=200"

if [ "$MODE" = seed ]; then
  CMD="/zpool.so create -f -o ashift=12 -O recordsize=8k -O compression=off -O atime=off -O sync=standard -O logbias=latency -O primarycache=all -O mountpoint=/data pgdata /dev/vblk1 ; /usr/bin/seed_copy /data-seed /data/pg ; /zpool.so export pgdata"
  MEM=8G; CPUS=8
else
  # 32 GiB guest / 32 vCPU: matches the prior leak-hunt so OOM reproduces ~round 280.
  CMD="/zpool.so import -f -N pgdata ; /zfs.so mount pgdata ; /usr/bin/postgres -D /data/pg $PGARGS"
  MEM=32G; CPUS=32
fi

BOOTARGS="--rootfs=rofs --ip=eth0,192.168.100.2,255.255.255.0 --defaultgw=192.168.100.1 --nameserver=192.168.100.1 $EXTRA"
KERN="$B/loader.elf"
QEMU=qemu-system-x86_64
MACHINE="-M pc -cpu host -enable-kvm"
ls -l "$KERN" "$B/usr.img"

set +x
CMDLINE="$BOOTARGS $CMD"
echo "BOOT CMDLINE: $CMDLINE" | tee -a "$LOG"
set -x

sudo docker exec -d bld bash -lc "cd /work/osv && exec $QEMU $MACHINE -smp $CPUS -m $MEM -nographic -vga none \
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
