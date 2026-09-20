#!/bin/bash
# Boot the OSv guest with NATIVE qemu (-M pc, host KVM). RAW NVMe passthrough.
# FOOTPRINT study variant: adds OSV_FP_PROBE + configurable -m / shared_buffers /
# max_connections so MAX-BACKENDS-BEFORE-OOM is a measurable sweep.
# ARGS: <mode: seed|run>.  Env knobs: GUESTMEM, SB, MAXCONN, TAG, FP_PROBE, MEM_PROBE,
#   FP_INTERVAL, plus the STEP-2 fix knobs (FP_ARENA_LAZY, FP_ARENA_SIZE, ...).
set -x
MODE="$1"
OSV=/work/osv
TAG="${TAG:-fp}"
B=/work/img-$TAG
[ -f "$B/loader.elf" ] || B=$OSV/build/last
POOLDEV=/dev/nvme1n1
LOG=/work/console-$MODE.log

IOMETHOD="${IOMETHOD:-io_uring}"
SB="${SB:-16GB}"
MAXCONN="${MAXCONN:-400}"
GUESTMEM="${GUESTMEM:-64G}"
CPUS="${CPUS:-32}"
PGARGS="-c listen_addresses=* -c max_connections=$MAXCONN -c shared_buffers=$SB \
-c effective_cache_size=32GB -c max_wal_size=64GB -c min_wal_size=2GB \
-c checkpoint_timeout=15min -c checkpoint_completion_target=0.9 -c log_checkpoints=on \
-c fsync=on -c synchronous_commit=on -c autovacuum=on -c io_method=$IOMETHOD \
-c shared_preload_libraries=plpgsql -c max_files_per_process=200"

if [ "$MODE" = seed ]; then
  CMD="/zpool.so create -f -o ashift=12 -O recordsize=8k -O compression=off -O atime=off -O sync=standard -O logbias=latency -O primarycache=all -O mountpoint=/data pgdata /dev/vblk1 ; /zpool.so get ashift pgdata ; /zfs.so list ; /usr/bin/seed_copy /data-seed /data/pg ; /zfs.so get used pgdata ; /zpool.so export pgdata"
  MEM=8G; CPUS=8
else
  CMD="/zpool.so import -f -N pgdata ; /zfs.so mount pgdata ; /zpool.so get ashift pgdata ; /usr/bin/postgres -D /data/pg $PGARGS"
  MEM=$GUESTMEM
fi

LEVERS="--env=OSV_ZFS_ARC_MAX=34359738368 --env=OSV_BLK_MQ_COMPLETE=1 --env=OSV_IDLE_SPIN_ADAPTIVE=1"
[ -n "${MEM_PROBE:-}" ]   && LEVERS="$LEVERS --env=OSV_MEM_PROBE=$MEM_PROBE"
[ -n "${FP_PROBE:-}" ]    && LEVERS="$LEVERS --env=OSV_FP_PROBE=$FP_PROBE"
[ -n "${FP_INTERVAL:-}" ] && LEVERS="$LEVERS --env=OSV_FP_INTERVAL=$FP_INTERVAL"
# STEP-2 fix knobs (each default-off in the kernel; set here for the AFTER arm)
[ -n "${ARENA_LAZY:-}" ]   && LEVERS="$LEVERS --env=OSV_FORK_ARENA_LAZY=$ARENA_LAZY"
[ -n "${ARENA_SIZE:-}" ]   && LEVERS="$LEVERS --env=OSV_FORK_ARENA_SIZE=$ARENA_SIZE"
[ -n "${ARENA_TRIM:-}" ]   && LEVERS="$LEVERS --env=OSV_FORK_ARENA_TRIM=$ARENA_TRIM"
[ -n "${LARGE_SHARE:-}" ]  && LEVERS="$LEVERS --env=OSV_FORK_LARGE_SHARE=$LARGE_SHARE"
[ -n "${EXTRA_ENV:-}" ]    && LEVERS="$LEVERS $EXTRA_ENV"

BOOTARGS="--rootfs=rofs $LEVERS --ip=eth0,192.168.100.2,255.255.255.0 --defaultgw=192.168.100.1 --nameserver=192.168.100.1"
CMDLINE="$BOOTARGS $CMD"

: > "$LOG"
echo "BOOT CMDLINE: $CMDLINE" >> "$LOG"
echo "BOOT IMG: $B  MEM=$MEM CPUS=$CPUS SB=$SB MAXCONN=$MAXCONN" >> "$LOG"

exec qemu-system-x86_64 -M pc -cpu host -enable-kvm -smp $CPUS -m $MEM -nographic -vga none \
  -kernel "$B/loader.elf" -append "$CMDLINE" \
  -drive file=$B/usr.img,if=none,id=hd0,cache=none,aio=native,format=qcow2 \
  -device virtio-blk-pci,drive=hd0,scsi=off \
  -drive file=$POOLDEV,if=none,id=hd1,cache=none,aio=native,format=raw \
  -device virtio-blk-pci,drive=hd1,scsi=off \
  -netdev tap,id=hn0,ifname=tap0,script=no,downscript=no,vhost=off \
  -device virtio-net-pci,netdev=hn0 \
  -device virtio-rng-pci \
  >> "$LOG" 2>&1
