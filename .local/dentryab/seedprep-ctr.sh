#!/bin/bash
# initdb the seed tree INSIDE the fedora bld container (has ld-musl-x86_64.so.1).
# The guest PG binary is a musl-dynamic x86-64 ELF; it runs in the container, not on AL2023.
set -x
cd /work/osv || exit 1
PGBIN=/work/osv/apps/postgres18-musl/install/bin
export LD_LIBRARY_PATH=$PGBIN/../lib
$PGBIN/postgres --version || { echo "FATAL postgres --version"; }
id pgu 2>/dev/null || useradd -m pgu
rm -rf /work/data-seed
mkdir -p /work/data-seed
chown -R pgu /work/data-seed
su pgu -c "env LD_LIBRARY_PATH=$LD_LIBRARY_PATH $PGBIN/initdb -D /work/data-seed -U postgres --locale=C --encoding=UTF8 -A trust" 2>&1 | tail -20
echo "INITDB_RC=$?"
ls /work/data-seed | head
grep -E '^shared_buffers|^max_wal_size' /work/data-seed/postgresql.conf
cat >> /work/data-seed/pg_hba.conf <<'EOF'
host all all 0.0.0.0/0 trust
EOF
echo "SEEDPREP_DONE size=$(du -sm /work/data-seed|cut -f1)MB"
