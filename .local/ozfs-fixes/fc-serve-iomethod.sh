#!/bin/bash
# Serve PG on the raidz "pgdata" pool under FIRECRACKER, cross-instance reachable.
# Benchmark PG config passed via -c flags (matches KVM + Linux control).
# HUGEPAGES + PARALLEL + SYNC are env-tunable for the matrix.
set -u
PGBIN=/b/.local/pg18/install/bin
GUEST=192.168.100.2
VCPUS="${VCPUS:-16}"
MEM="${MEM:-40960}"          # MiB guest RAM (shared_buffers 8G + effective_cache 24G headroom)
HUGEPAGES="${HUGEPAGES:-off}"
SYNCMODE="${SYNCMODE:-disabled}"   # zfs sync= ; disabled for smoke, standard for durability
PARALLEL="${PARALLEL:-8}"

# Benchmark postgresql config (identical across Linux / OSv-KVM / OSv-FC)
PGC="-c shared_buffers=8GB -c effective_cache_size=24GB -c work_mem=32MB"
PGC="$PGC -c max_connections=256 -c max_wal_size=16GB -c checkpoint_timeout=15min"
PGC="$PGC -c synchronous_commit=on -c io_method=sync -c max_parallel_workers=$PARALLEL"
PGC="$PGC -c max_parallel_workers_per_gather=2 -c listen_addresses=* -c port=5432"
if [ "$HUGEPAGES" = on ]; then PGC="$PGC -c huge_pages=on"; else PGC="$PGC -c huge_pages=off"; fi

INIT="/zpool.so import -f -N pgdata ; /zfs.so set sync=$SYNCMODE pgdata ; /zfs.so mount pgdata ; $PGBIN/postgres -D /data $PGC"
echo "== FC serve: vcpus=$VCPUS mem=${MEM}M hugepages=$HUGEPAGES sync=$SYNCMODE parallel=$PARALLEL =="
rm -f /tmp/fc-serve.log
sudo timeout "${RUNSECS:-0}" python3 /tmp/fc-run.py --append "--rootfs=zfs $INIT" --vcpus "$VCPUS" --mem "$MEM" --net > /tmp/fc-serve.log 2>&1 &
echo $! > /tmp/fc.pid
# wait for readiness
for i in $(seq 1 120); do
  sleep 1
  grep -q "ready to accept" /tmp/fc-serve.log 2>/dev/null && { echo "READY at ${i}s"; break; }
  grep -qi "abort\|panic\|Assertion failed" /tmp/fc-serve.log && { echo "CRASH:"; tail -20 /tmp/fc-serve.log; break; }
done
grep -q "ready to accept" /tmp/fc-serve.log || { echo NOT_READY; tail -25 /tmp/fc-serve.log; }
