#!/bin/bash
# rss-linux-pgstart.sh -- on Linux-native: initdb PG18 on ext4 /data/pg, config to MATCH OSv
# serve knobs (shared_buffers=4GB, effective_cache_size=12GB, max_connections=200, huge_pages=off,
# listen_addresses=*, DEFAULT mmap = default shared_memory_type), trust auth. Start.
set -eu
PGBIN=$(ls -d /usr/pgsql-18/bin 2>/dev/null || echo /usr/bin)
[ -x "$PGBIN/initdb" ] || PGBIN=/usr/bin
DATA=/data/pg
sudo -u postgres bash -c "
set -e
'$PGBIN/initdb' -D '$DATA' -U postgres --locale-provider=builtin --builtin-locale=C -E UTF8 -A trust
cat >> '$DATA/postgresql.conf' <<CFG
listen_addresses = '*'
port = 5432
unix_socket_directories = ''
shared_buffers = 4GB
effective_cache_size = 12GB
max_connections = 200
huge_pages = off
shared_preload_libraries = 'plpgsql'
CFG
echo 'host all all 0.0.0.0/0 trust' >> '$DATA/pg_hba.conf'
"
sudo -u postgres "$PGBIN/pg_ctl" -D "$DATA" -l /tmp/pg.log -w start 2>&1 | tail -3
sleep 2
sudo -u postgres "$PGBIN/psql" -p 5432 -tAc "select 1, version()" 2>&1
echo LINUX_PG_UP
