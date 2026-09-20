#!/bin/bash
# Start PostgreSQL on the Ubuntu guest with the SAME mandated GUCs + io_method=io_uring as OSv.
# Runs inside the guest (sudo). Idempotent: stops any running PG first.
set -x
PGBIN=/usr/lib/postgresql/18/bin
# import pool if not mounted (fresh boot)
sudo zpool import -f pgdata 2>/dev/null
sudo zfs mount pgdata 2>/dev/null
sudo chown -R postgres /data 2>/dev/null
PGARGS="-c listen_addresses=* -c max_connections=400 -c shared_buffers=16GB \
-c effective_cache_size=32GB -c max_wal_size=64GB -c min_wal_size=2GB \
-c checkpoint_timeout=15min -c checkpoint_completion_target=0.9 -c log_checkpoints=on \
-c fsync=on -c synchronous_commit=on -c autovacuum=on -c io_method=io_uring \
-c shared_preload_libraries=plpgsql -c max_files_per_process=200"
sudo -u postgres setsid --fork $PGBIN/postgres -D /data/pg $PGARGS >/tmp/pg.log 2>&1
sleep 5
echo "PG_STARTED pid=$(pgrep -f 'postgres -D /data/pg'|head -1)"
tail -3 /tmp/pg.log
