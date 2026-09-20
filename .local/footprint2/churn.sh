#!/bin/bash
# N churning sessions, each ONE backend doing continuous per-query MemoryContext
# turnover with a tiny live result -- the PostgreSQL pattern the no-op overflow
# free() punishes. Backend count is FIXED for the window, so CHURN is the only
# variable versus the idle arm (which holds the same count and does nothing).
# ARGS: <n> <seconds> <rows>   env: PGHOST required
N="${1:-64}"
SECS="${2:-180}"
ROWS="${3:-50000}"
: "${PGHOST:?set PGHOST}"
export PGPASSWORD="${PGPASSWORD:-postgres}" PGHOST PGUSER=postgres PGDATABASE=postgres
Q="SELECT sum(x) FROM (SELECT (g*7919)%100003 AS x FROM generate_series(1,$ROWS) g ORDER BY 1) t"
BKQ="select count(*) from pg_stat_activity where backend_type='client backend'"

echo "CHURN start n=$N secs=$SECS rows=$ROWS host=$PGHOST"
for i in $(seq 1 "$N"); do
  (
    END=$(( $(date +%s) + SECS ))
    while [ "$(date +%s)" -lt "$END" ]; do
      psql -q -tAc "$Q" >/dev/null 2>&1
    done
  ) &
done

sleep 5
END=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt "$END" ]; do
  BK=$(timeout 20 psql -tAc "$BKQ" 2>/dev/null | tr -d ' ')
  echo "t=$(date +%s) bk=${BK:-?}"
  sleep 15
done
wait 2>/dev/null
echo CHURN_DONE
