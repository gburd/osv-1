#!/bin/bash
# Orchestrate the OSv+PG Firecracker snapshot/restore prototype on osv-fcsnap.
# Single-file ZFS pool (recordsize=8k lz4). Cluster seeded from a HOST-initdb'd
# data-init via cpiod (in-guest initdb is unsupported on this OSv image).
#
#   /mnt/fc/pool.raw          - live ZFS pool backing file (vblk1)
#   /mnt/fc/pool-pristine.raw - post-seed pristine, snapshot-consistent copy
#   /mnt/fc/snap/             - snapshot vmstate + mem files
set -u
WORK=/mnt/fc
SNAP=$WORK/snap
POOL=$WORK/pool.raw
PRISTINE=$WORK/pool-pristine.raw
PGBIN=/b/.local/pg18/install/bin
SRC=/b/.local/pg18/data-init
GUEST=192.168.100.2
HOSTBIND=192.168.100.2            # guest virtio-net IP (host->tap->guest, real net path)
SNAPPY=/tmp/fc-snap.py
FCLOG=/tmp/fc-console.log
VMSTATE=$SNAP/osvpg.vmstate
MEM=$SNAP/osvpg.mem
export PGCONNECT_TIMEOUT=4

POOLPROPS="-o ashift=12"
FSPROPS="-O compression=lz4 -O atime=off -O recordsize=8k -O logbias=throughput -O primarycache=all"

step_prep() {
  sudo mkdir -p $WORK $SNAP
  if ! mountpoint -q $WORK; then
    if ! blkid /dev/nvme0n1 >/dev/null 2>&1; then sudo mkfs.xfs -f /dev/nvme0n1 >/dev/null 2>&1; fi
    sudo mount /dev/nvme0n1 $WORK 2>/dev/null || true
    sudo mkdir -p $SNAP
  fi
  sudo chown -R ec2-user:ec2-user $WORK
  echo "prep: $WORK ready ($(df -h $WORK | tail -1 | awk '{print $4}') free)"
}

step_tap() { sudo bash /tmp/fc-tap-net.sh 2>&1 | sed 's/^/[tap] /'; }

# create pool + cpiod-seed the host-initdb'd cluster into /data, export clean
step_seed() {
  echo "=== create 8G pool + cpiod-seed cluster into /data ==="
  rm -f $POOL $PRISTINE; truncate -s 8G $POOL
  local CREATE="/zpool.so create -f $POOLPROPS $FSPROPS -m /data pgdata /dev/vblk1"
  local INIT="$CREATE ; /zfs.so set sync=disabled pgdata ; /tools/cpiod.so --prefix /data/ --port 10000 ; /zpool.so export pgdata"
  sudo python3 $SNAPPY boot --append "--rootfs=zfs $INIT" --vcpus 8 --mem 16384 \
       --members "$POOL" --net --fclog $FCLOG 2>&1 | sed 's/^/[seed] /' &
  # wait for cpiod ready
  for i in $(seq 1 60); do
    sleep 1
    grep -qi "Waiting for connection from host" $FCLOG 2>/dev/null && { echo "cpiod ready @${i}s"; break; }
    grep -qiE "assert|abort|panic|Failed to load" $FCLOG 2>/dev/null && { echo "SEED CRASH"; tail -15 $FCLOG; return 1; }
  done
  sleep 1
  echo "--- pushing cluster ($(du -sh $SRC | cut -f1)) ---"
  python3 /tmp/cpio_push.py "$SRC" "$GUEST" 10000 2>&1 | sed 's/^/[push] /' | tail -3
  echo "--- waiting for export + poweroff ---"
  for i in $(seq 1 60); do
    sleep 1
    grep -qiE "Powering off|exit_code=0" $FCLOG 2>/dev/null && break
  done
  sleep 2; sudo pkill -9 firecracker 2>/dev/null; wait 2>/dev/null
  grep -iE "export|Powering|creating|cpiod|error|FATAL" $FCLOG | tail -8
  cp $POOL $PRISTINE
  echo "pristine pool saved ($(du -h $PRISTINE | cut -f1))"
}

# boot to ready on a fresh copy of the pristine pool; leave running (API sock live)
step_boot_ready() {
  echo "=== boot OSv+PG to READY (cold) ==="
  cp $PRISTINE $POOL
  local SERVE="/zpool.so import -f -N pgdata ; /zfs.so set sync=disabled pgdata ; /zfs.so mount pgdata ; $PGBIN/postgres -D /data"
  local t0=$(date +%s.%N)
  # NB: no --wait; fc-snap.py returns after InstanceStart, FC keeps running (orphaned child),
  # API socket stays live for snapshot.
  sudo -b python3 $SNAPPY boot --append "--rootfs=zfs $SERVE" --vcpus 8 --mem 16384 \
       --members "$POOL" --net --fclog $FCLOG --pidfile /tmp/fc.pid >/tmp/fc-boot.out 2>&1
  sleep 2
  for i in $(seq 1 120); do
    sleep 0.5
    grep -qa "ready to accept" $FCLOG 2>/dev/null && { local t1=$(date +%s.%N); echo "READY (cold boot->ready = $(echo "$t1-$t0"|bc)s)"; break; }
    grep -qiE "assert|abort|panic|Assertion failed|Failed to load" $FCLOG 2>/dev/null && { echo "BOOT CRASH"; tail -25 $FCLOG; return 1; }
  done
  grep -qa "ready to accept" $FCLOG || { echo NOT_READY; tail -30 $FCLOG; return 1; }
}

step_marker() {
  echo "=== marker table + row BEFORE snapshot ==="
  psql -h $HOSTBIND -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
create table if not exists snapmark(id int primary key, note text, created timestamptz default now());
insert into snapmark(id,note) values (42,'pre-snapshot-row') on conflict (id) do update set note=excluded.note;
select 'MARKER-PRESNAP', id, note, created from snapmark where id=42;
SQL
}

step_snapshot() {
  echo "=== PAUSE + FULL snapshot (memory+vmstate) ==="
  rm -f $VMSTATE $MEM
  sudo python3 $SNAPPY snapshot --socket /tmp/fc.sock --snap-vmstate $VMSTATE --snap-mem $MEM 2>&1 | sed 's/^/[snap] /'
  sudo pkill -9 firecracker 2>/dev/null; sleep 1
  echo "--- snapshot file sizes ---"
  ls -la $VMSTATE $MEM
  du -h $VMSTATE $MEM
  # save the exact pool state at snapshot time (memory<->disk consistency baseline)
  cp $POOL $WORK/pool-at-snapshot.raw
  echo "pool-at-snapshot saved"
}

# one restore + measured first-query. Uses a FRESH copy of the snapshot-time pool.
step_restore_once() {
  local RUN="${1:-1}"
  sudo pkill -9 firecracker 2>/dev/null; sleep 0.5
  cp $WORK/pool-at-snapshot.raw $POOL           # COW-equivalent: fresh disk == memory
  # T0 = firecracker restore invocation; restore resumes vm.
  sudo python3 $SNAPPY restore --socket /tmp/fc.sock --members "$POOL" \
       --snap-vmstate $VMSTATE --snap-mem $MEM --fclog /tmp/fc-restore.log \
       --pidfile /tmp/fc.pid --tstamp /tmp/fc-restore.tstamp 2>&1 | sed 's/^/[restore] /'
  local T0=$(grep '^T0' /tmp/fc-restore.tstamp | awk '{print $2}')
  local T1=$(grep '^T1' /tmp/fc-restore.tstamp | awk '{print $2}')
  # T2 = first successful external select 1
  local T2=""
  for i in $(seq 1 400); do
    if psql -h $HOSTBIND -U postgres -d postgres -tAc "select 1" 2>/dev/null | grep -q "^1$"; then
      T2=$(date +%s.%N); break
    fi
    sleep 0.01
  done
  if [ -z "$T2" ]; then echo "RUN$RUN: NO first-query (restore may have failed)"; tail -20 /tmp/fc-restore.log; return 1; fi
  local RESUME=$(echo "$T1-$T0"|bc); local FIRSTQ=$(echo "$T2-$T0"|bc)
  echo "RUN$RUN: FC-resume(T1-T0)=${RESUME}s  restore->first-query(T2-T0)=${FIRSTQ}s"
  echo "$RUN $RESUME $FIRSTQ" >> /tmp/fc-restore-results.tsv
}

step_verify_data() {
  echo "=== verify REAL data survives restore (marker row readable) ==="
  psql -h $HOSTBIND -U postgres -d postgres -tAc \
    "select id||'|'||note||'|'||created from snapmark where id=42" 2>/dev/null
  echo "=== clock skew check: guest now() vs host wall ==="
  echo "host: $(date -u +%FT%T.%3NZ)"
  psql -h $HOSTBIND -U postgres -d postgres -tAc "select 'guest:'||now()" 2>/dev/null
}

case "${1:-}" in
  prep) step_prep ;;
  tap) step_tap ;;
  seed) step_prep; step_tap; step_seed ;;
  boot) step_prep; step_tap; step_boot_ready ;;
  marker) step_marker ;;
  snapshot) step_snapshot ;;
  restore) step_restore_once "${2:-1}" ;;
  verify) step_verify_data ;;
  *) echo "usage: $0 {prep|tap|seed|boot|marker|snapshot|restore N|verify}"; exit 1 ;;
esac
