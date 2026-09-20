#!/bin/bash
# CHURN arm, LONG-LIVED backends -- the shape that actually matters.
#
# Each session is ONE backend (one fork) that then runs MANY queries inside that
# same session via \watch. That is the HammerDB/VU pattern and the one the
# churn-proportional bug punishes: the backend never exits, so its overflow
# regions are never reaped, and without intra-AS recycling its committed RAM
# grows with every query it serves.
#
# (An earlier version reconnected psql per query, which made every query a fresh
# fork+reap -- the reap hid the bug, because teardown reclaims the region
# wholesale. Long-lived sessions are required to see it.)
#
# ARGS: <n> <seconds> <rows>   env: PGHOST required
N="${1:-64}"
SECS="${2:-180}"
ROWS="${3:-50000}"
: "${PGHOST:?set PGHOST}"
export PGPASSWORD="${PGPASSWORD:-postgres}" PGHOST PGUSER=postgres PGDATABASE=postgres
BKQ="select count(*) from pg_stat_activity where backend_type='client backend'"

echo "CHURN-LL start n=$N secs=$SECS rows=$ROWS host=$PGHOST"
for i in $(seq 1 "$N"); do
  (
    # ONE connection, held for the whole window, re-running the churn query.
    psql -q -v ON_ERROR_STOP=0 <<SQL >/dev/null 2>&1
SELECT sum(x) FROM (SELECT (g*7919)%100003 AS x FROM generate_series(1,$ROWS) g ORDER BY 1) t
\watch 0.05
SQL
  ) &
done

sleep 5
END=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt "$END" ]; do
  BK=$(timeout 20 psql -tAc "$BKQ" 2>/dev/null | tr -d ' ')
  echo "t=$(date +%s) bk=${BK:-?}"
  sleep 15
done
# \watch never returns; end the arm at the deadline.
pkill -P $$ psql 2>/dev/null
kill $(jobs -p) 2>/dev/null
wait 2>/dev/null
echo CHURN_LL_DONE
