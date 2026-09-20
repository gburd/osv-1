#!/bin/bash
# Boot the OSv guest with NATIVE qemu 7.2.22 (-M pc, host KVM). RAW NVMe passthrough:
# /dev/nvme1n1 straight through (cache=none aio=native). io_method=io_uring + all levers.
# This script EXECS qemu in the foreground; the CALLER detaches it (setsid --fork at ssh level).
# ARGS: <mode: seed|run>   LOG is fixed per mode so the poller always knows where to look.
set -x
MODE="$1"
OSV=/work/osv
B=$OSV/build/last
POOLDEV=/dev/nvme1n1
LOG=/work/console-$MODE.log

IOMETHOD="${IOMETHOD:-io_uring}"
PGARGS="-c listen_addresses=* -c max_connections=400 -c shared_buffers=16GB \
-c effective_cache_size=32GB -c max_wal_size=64GB -c min_wal_size=2GB \
-c checkpoint_timeout=15min -c checkpoint_completion_target=0.9 -c log_checkpoints=on \
-c fsync=on -c synchronous_commit=on -c autovacuum=on -c io_method=$IOMETHOD \
-c shared_preload_libraries=plpgsql -c max_files_per_process=200"

if [ "$MODE" = seed ]; then
  CMD="/zpool.so create -f -o ashift=12 -O recordsize=8k -O compression=off -O atime=off -O sync=standard -O logbias=latency -O primarycache=all -O mountpoint=/data pgdata /dev/vblk1 ; /zpool.so get ashift pgdata ; /zfs.so list ; /usr/bin/seed_copy /data-seed /data/pg ; /zfs.so get used pgdata ; /zpool.so export pgdata"
  MEM=8G; CPUS=8
else
  CMD="/zpool.so import -f -N pgdata ; /zfs.so mount pgdata ; /zpool.so get ashift pgdata ; /usr/bin/postgres -D /data/pg $PGARGS"
  MEM=64G; CPUS=32
fi

# Adaptive idle-spin A/B knob (Gate 2 + Gate 1). The runcell exports these before
# launching /tmp/boot-osv.sh so the same image serves both arms:
#   ADAPT=1 (default)  -> OSV_IDLE_SPIN_ADAPTIVE=1  (adaptive-v2, the fix under test)
#   ADAPT=0            -> OSV_IDLE_SPIN_ADAPTIVE=0 + OSV_IDLE_SPIN=<FIXEDSPIN>
#                         (fixed count; FIXEDSPIN=10000 = the historical baseline)
ADAPT="${ADAPT:-1}"
FIXEDSPIN="${FIXEDSPIN:-10000}"
if [ "$ADAPT" = 1 ]; then
  SPINLEVER="--env=OSV_IDLE_SPIN_ADAPTIVE=1"
else
  SPINLEVER="--env=OSV_IDLE_SPIN_ADAPTIVE=0 --env=OSV_IDLE_SPIN=$FIXEDSPIN"
fi
LEVERS="--env=OSV_ZFS_ARC_MAX=34359738368 --env=OSV_BLK_MQ_COMPLETE=1 $SPINLEVER"
# cwwake A/B knobs (default off -> stock baseline). Passed through to the guest.
if [ -n "${FLUSH_INLINE:-}" ]; then LEVERS="$LEVERS --env=OSV_ZIL_FLUSH_INLINE=$FLUSH_INLINE"; fi
if [ -n "${WEDGE_PROBE:-}" ]; then LEVERS="$LEVERS --env=OSV_ZIL_WEDGE_PROBE=$WEDGE_PROBE"; fi
if [ -n "${INTR_THREADS:-}" ]; then LEVERS="$LEVERS --env=OSV_ZIO_INTR_THREADS=$INTR_THREADS"; fi
if [ -n "${WAKE_IPI_ALWAYS:-}" ]; then LEVERS="$LEVERS --env=OSV_WAKE_IPI_ALWAYS=$WAKE_IPI_ALWAYS"; fi
if [ -n "${NO_MORPH:-}" ]; then LEVERS="$LEVERS --env=OSV_CONDVAR_NO_MORPH=$NO_MORPH"; fi
if [ -n "${ZIL_WAIT_TIMEOUT:-}" ]; then LEVERS="$LEVERS --env=OSV_ZIL_WAIT_TIMEOUT=$ZIL_WAIT_TIMEOUT"; fi
if [ -n "${MEM_PROBE:-}" ]; then LEVERS="$LEVERS --env=OSV_MEM_PROBE=$MEM_PROBE"; fi
BOOTARGS="--rootfs=rofs $LEVERS --ip=eth0,192.168.100.2,255.255.255.0 --defaultgw=192.168.100.1 --nameserver=192.168.100.1"
CMDLINE="$BOOTARGS $CMD"

# fresh log each boot (truncate)
: > "$LOG"
echo "BOOT CMDLINE: $CMDLINE" >> "$LOG"
echo "SPINLEVER: $SPINLEVER (ADAPT=$ADAPT FIXEDSPIN=$FIXEDSPIN)" >> "$LOG"

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
