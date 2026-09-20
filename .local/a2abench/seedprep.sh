#!/bin/bash
# Host-side initdb for the seed tree, using the musl PG built for the GUEST arch.
# On x86 the guest binary runs natively on the host, so we can initdb directly.
# On aarch64 host + aarch64 guest, likewise. (No cross-arch case here.)
set -x
exec > /work/seedprep.log 2>&1
cd /work/osv || exit 1
PGBIN=/work/osv/apps/postgres18-musl/install/bin
ls -l $PGBIN/initdb $PGBIN/postgres || { echo FATAL no pg binaries; exit 1; }
$PGBIN/postgres --version

rm -rf /work/data-seed
mkdir -p /work/data-seed
# initdb must run as non-root
sudo chown -R ec2-user /work/data-seed
sudo -u ec2-user env LD_LIBRARY_PATH=$PGBIN/../lib $PGBIN/initdb -D /work/data-seed -U postgres \
  --locale=C --encoding=UTF8 -A trust 2>&1 | tail -20
echo "INITDB_RC=$?"
ls /work/data-seed | head
grep -E '^shared_buffers|^max_wal_size' /work/data-seed/postgresql.conf

# hba: allow the driver subnet + local
cat >> /work/data-seed/pg_hba.conf <<'EOF'
host all all 0.0.0.0/0 trust
EOF
echo "SEEDPREP_DONE size=$(du -sm /work/data-seed|cut -f1)MB"
