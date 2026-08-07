#!/bin/bash
# JOB E MQ A/B benchmark. Runs pgbench RO (-S) and RW at several concurrencies
# against the OSv guest at 192.168.100.2:5432. $1 = label (mqN / nqp1).
set -u
HOST=192.168.100.2; PORT=5432
PGBENCH="pgbench -h $HOST -p $PORT -U postgres"
export PGCONNECT_TIMEOUT=10 PGPASSWORD=
LABEL="${1:-run}"
DUR="${DUR:-25}"; SCALE="${SCALE:-50}"
OUT=/mnt/nvme/mqbench-$LABEL.txt
: > "$OUT"
echo "== MQ bench label=$LABEL scale=$SCALE dur=${DUR}s ==" | tee -a "$OUT"
# init once
timeout 120 $PGBENCH -i -s "$SCALE" -d postgres >/mnt/nvme/mqbench-init-$LABEL.log 2>&1 || echo "init warn" | tee -a "$OUT"
tps() { grep -E '^tps' | grep -oE '[0-9]+\.[0-9]+' | head -1; }
for c in 8 16 32 48; do
  RO=$(timeout $((DUR+30)) $PGBENCH -S -c $c -j 8 -T "$DUR" -d postgres 2>/dev/null | tps)
  echo "RO c$c: ${RO:-FAIL} tps" | tee -a "$OUT"
done
for c in 8 16 32 48; do
  R=$(timeout $((DUR+40)) $PGBENCH -c $c -j 8 -T "$DUR" -d postgres 2>/dev/null | tps)
  echo "RW c$c: ${R:-FAIL} tps" | tee -a "$OUT"
done
echo "== done label=$LABEL ==" | tee -a "$OUT"
