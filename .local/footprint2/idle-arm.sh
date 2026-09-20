#!/bin/bash
# IDLE arm of the churn discriminator: the SAME backend count as the churn arm,
# each backend established by one trivial query and then held open doing NOTHING.
# Fixed-per-fork cost predicts this costs the same as the churn arm.
# Churn-proportional predicts it costs far less.
# ARGS: <n> <seconds>   env: PGHOST required
N="${1:-64}"
SECS="${2:-180}"
: "${PGHOST:?set PGHOST}"
export PGPASSWORD="${PGPASSWORD:-postgres}" PGHOST PGUSER=postgres PGDATABASE=postgres
BKQ="select count(*) from pg_stat_activity where backend_type='client backend'"

echo "IDLE start n=$N secs=$SECS host=$PGHOST"
for i in $(seq 1 "$N"); do
  # One trivial query (forks the backend, builds relcache/catcache), then park.
  ( psql -q -tAc "SELECT 1" -c "SELECT pg_sleep($SECS)" >/dev/null 2>&1 ) &
done

sleep 5
END=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt "$END" ]; do
  BK=$(timeout 20 psql -tAc "$BKQ" 2>/dev/null | tr -d ' ')
  echo "t=$(date +%s) bk=${BK:-?}"
  sleep 15
done
wait 2>/dev/null
echo IDLE_DONE
