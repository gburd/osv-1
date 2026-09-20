#!/bin/bash
# Boot the OSv PG18 guest natively (qemu 7.2 -M pc) with raw NVMe passthrough
# for the ZFS pool and tap0 networking (DNAT 5432 -> guest).
# Modes: seed (create pool + seed_copy, export), run (import + start PG).
# ARGS: <seed|run> [extra-boot-env e.g. --env=OSV_IDLE_SPIN=200000]
set -x
MODE="$1"; shift
EXTRA="$*"
B=/work/osv/build/last
DATADISK=$(cat /work/DATADISK 2>/dev/null || echo /dev/nvme0n1)
LOG=/work/pgconsole-$MODE-$(date +%H%M%S).log
KERN=$B/loader.elf
IMG=$B/usr.img
CPUS=32; MEM=32G
NQ=${POOL_NUM_QUEUES:-8}

# 12 mandated GUCs on the command line (source='command line').
PGARGS="-c listen_addresses=* -c max_connections=400 -c shared_buffers=16GB \
-c effective_cache_size=32GB -c max_wal_size=64GB -c min_wal_size=2GB \
-c checkpoint_timeout=15min -c checkpoint_completion_target=0.9 -c log_checkpoints=on \
-c fsync=on -c synchronous_commit=on -c autovacuum=on -c io_method=sync \
-c shared_preload_libraries=plpgsql -c max_files_per_process=200"

if [ "$MODE" = seed ]; then
  sudo dd if=/dev/zero of="$DATADISK" bs=1M count=16 conv=fsync 2>/dev/null
  CMD="/zpool.so create -f -o ashift=12 -O recordsize=8k -O compression=off -O atime=off -O sync=standard -O logbias=latency -O primarycache=all -O mountpoint=/data pgdata /dev/vblk1 ; /zfs.so list ; /usr/bin/seed_copy /data-seed /data/pg ; /zpool.so export pgdata"
else
  CMD="/zpool.so import -f -N pgdata ; /zfs.so mount pgdata ; /zpool.so get ashift pgdata ; /zfs.so get recordsize,sync,logbias,primarycache pgdata ; /usr/bin/postgres -D /data/pg $PGARGS"
fi

BOOTARGS="--rootfs=rofs --ip=eth0,192.168.100.2,255.255.255.0 --defaultgw=192.168.100.1 --nameserver=192.168.100.1 $EXTRA"
CMDLINE="$BOOTARGS $CMD"
echo "BOOT: $CMDLINE" | tee -a "$LOG"

pkill -9 -f qemu-system-x86 2>/dev/null; sleep 2
sudo ip link set tap0 up 2>/dev/null
# native qemu 7.2 -M pc; raw NVMe passthrough as vblk1 (num-queues); rofs image vblk0.
sudo nohup qemu-system-x86_64 -M pc -cpu host -enable-kvm -nographic -vga none \
  -smp $CPUS -m $MEM \
  -kernel "$KERN" -append "$CMDLINE" \
  -drive file=$IMG,if=none,id=hd0,cache=none,aio=native,format=qcow2 \
  -device virtio-blk-pci,drive=hd0,scsi=off \
  -drive file=$DATADISK,if=none,id=hd1,cache=none,aio=native,format=raw \
  -device virtio-blk-pci,drive=hd1,scsi=off,num-queues=$NQ \
  -netdev tap,id=hn0,ifname=tap0,script=no,downscript=no,vhost=off \
  -device virtio-net-pci,netdev=hn0 \
  -device virtio-rng-pci \
  >> "$LOG" 2>&1 &
echo "QEMU_PID=$! LOG=$LOG"
sleep 3
tail -5 "$LOG"
