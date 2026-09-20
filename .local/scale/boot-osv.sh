#!/bin/bash
# Boot the OSv guest with NATIVE qemu 7.2.22 (-M pc, host KVM). RAW NVMe passthrough.
# SCALE RE-TEST variant: the footprint FIX build (compile-time FORK_OVF_RECYCLE_DEFAULT),
# with the footprint probe ON so per-backend MB is measured every cell as VU rises.
# ARGS: <mode: seed|run>
# Env: GUESTMEM SB MAXCONN CPUS IOMETHOD SYNCCOMMIT TAG FP_INTERVAL
set -x
MODE="$1"
OSV=/work/osv
TAG="${TAG:-fix}"
B=/work/img-$TAG
[ -f "$B/loader.elf" ] || B=$OSV/build/last
POOLDEV=/dev/nvme1n1
LOG=/work/console-$MODE.log

IOMETHOD="${IOMETHOD:-io_uring}"
SB="${SB:-16GB}"
MAXCONN="${MAXCONN:-400}"
GUESTMEM="${GUESTMEM:-64G}"
CPUS="${CPUS:-32}"
# NON-DURABLE control for the #4 discriminator: synchronous_commit=off + fsync=off
# removes the per-commit ZIL/WAL durability path. DURABLE (default) = on/on.
SYNCCOMMIT="${SYNCCOMMIT:-on}"
FSYNC="${FSYNC:-on}"
PGARGS="-c listen_addresses=* -c max_connections=$MAXCONN -c shared_buffers=$SB \
-c effective_cache_size=32GB -c max_wal_size=64GB -c min_wal_size=2GB \
-c checkpoint_timeout=15min -c checkpoint_completion_target=0.9 -c log_checkpoints=on \
-c fsync=$FSYNC -c synchronous_commit=$SYNCCOMMIT -c autovacuum=on -c io_method=$IOMETHOD \
-c shared_preload_libraries=plpgsql -c max_files_per_process=200"

if [ "$MODE" = seed ]; then
  CMD="/zpool.so create -f -o ashift=12 -O recordsize=8k -O compression=off -O atime=off -O sync=standard -O logbias=latency -O primarycache=all -O mountpoint=/data pgdata /dev/vblk1 ; /zpool.so get ashift pgdata ; /zfs.so list ; /usr/bin/seed_copy /data-seed /data/pg ; /zfs.so get used pgdata ; /zpool.so export pgdata"
  MEM=8G; CPUS=8
else
  CMD="/zpool.so import -f -N pgdata ; /zfs.so mount pgdata ; /zpool.so get ashift pgdata ; /usr/bin/postgres -D /data/pg $PGARGS"
  MEM=$GUESTMEM
fi

# LEVERS. The ENV RULE: --env DOES reach getenv() for consumers that latch AFTER
# parse_options (loader.cc:818). Every lever below is either self-printing
# (WAKE_PULL printf, BLK_MQ queue count, FORKARENA ovf_recycle debug_early) or
# read back from the guest post-boot (ARC via MEMPROBE/console, io_method via SQL).
# The footprint fix arm itself is COMPILE-TIME (FORK_OVF_RECYCLE_DEFAULT=1) and
# prints "FORKARENA ovf_recycle=" via debug_early -> always on the console.
LEVERS="--env=OSV_ZFS_ARC_MAX=34359738368 --env=OSV_BLK_MQ_COMPLETE=1 --env=OSV_IDLE_SPIN_ADAPTIVE=1 --env=OSV_WAKE_PULL=1"
FP_INTERVAL="${FP_INTERVAL:-10}"
LEVERS="$LEVERS --env=OSV_FP_INTERVAL=$FP_INTERVAL"
[ -n "${EXTRA_ENV:-}" ] && LEVERS="$LEVERS $EXTRA_ENV"

BOOTARGS="--rootfs=rofs $LEVERS --ip=eth0,192.168.100.2,255.255.255.0 --defaultgw=192.168.100.1 --nameserver=192.168.100.1"
CMDLINE="$BOOTARGS $CMD"

: > "$LOG"
echo "BOOT CMDLINE: $CMDLINE" >> "$LOG"
echo "BOOT IMG: $B  MEM=$MEM CPUS=$CPUS SB=$SB MAXCONN=$MAXCONN IOMETHOD=$IOMETHOD SYNCCOMMIT=$SYNCCOMMIT FSYNC=$FSYNC" >> "$LOG"
echo "BOOT IMG SHA: $(sha256sum $B/usr.img 2>/dev/null | cut -c1-16) loader=$(sha256sum $B/loader.elf 2>/dev/null | cut -c1-16)" >> "$LOG"

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
