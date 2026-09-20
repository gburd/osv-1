#!/bin/bash
# Host-side initdb for the seed tree, using the musl PG binary INSIDE the fedora build
# container (the Debian host has no musl loader). Produces /work/data-seed with the C
# locale, trust hba on the driver subnet.
set -x
exec > /work/seedprep.log 2>&1
PGBIN=/work/osv/apps/postgres18-musl/install/bin
LIB=/work/osv/apps/postgres18-musl/install/lib

sudo docker exec bld bash -lc "
  set -x
  rm -rf /work/data-seed
  mkdir -p /work/data-seed
  useradd -m pgseed 2>/dev/null || true
  chown -R pgseed /work/data-seed
  su pgseed -s /bin/sh -c 'LD_LIBRARY_PATH=$LIB $PGBIN/initdb -D /work/data-seed -U postgres --locale=C --encoding=UTF8 -A trust' 2>&1 | tail -20
  echo INITDB_RC=\$?
  ls /work/data-seed | head
  grep -E '^shared_buffers|^max_wal_size' /work/data-seed/postgresql.conf
  cat >> /work/data-seed/pg_hba.conf <<'EOF'
host all all 0.0.0.0/0 trust
EOF
  echo listen_addresses=\\'*\\' >> /work/data-seed/postgresql.conf
"
echo "SEEDPREP_DONE size=$(sudo du -sm /work/data-seed 2>/dev/null | cut -f1)MB"
