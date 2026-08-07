#!/bin/bash
# repro-c8.sh -- pgbench baseline (c1) then the concurrent-write wedge (c8) RW.
# Run on the HOST (psql/pgbench from fedora libpq, or built pgbench). DB @ guest.
set -u
DB=192.168.100.2
PGBENCH="${PGBENCH:-/mnt/nvme/osv/.local/pg18/install/bin/pgbench}"
export LD_LIBRARY_PATH=/mnt/nvme/osv/.local/pg18/install/lib
export PGCONNECT_TIMEOUT=10
SCALE="${SCALE:-50}"

echo "== pgbench init -s$SCALE =="
timeout 300 "$PGBENCH" -h $DB -p 5432 -U postgres -i -s"$SCALE" postgres 2>&1 | tail -4

echo "== BASELINE: pgbench RW -c1 -T20 =="
timeout 60 "$PGBENCH" -h $DB -p 5432 -U postgres -c1 -j1 -T20 postgres 2>&1 | grep -E "tps|failed|number of trans" | tail -4

echo "== WEDGE PROBE: pgbench RW -c8 -T30 (expect HANG) =="
timeout 90 "$PGBENCH" -h $DB -p 5432 -U postgres -c8 -j8 -T30 postgres 2>&1 | grep -E "tps|failed|number of trans" | tail -6
RC=$?
echo "== c8 pgbench exit rc=$RC (124 = timeout = WEDGE CONFIRMED) =="
