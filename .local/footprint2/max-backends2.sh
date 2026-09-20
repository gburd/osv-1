#!/bin/bash
# MAX BACKENDS, memory-criterion version.
#
# The first sweep ended at "DIED_AT_TARGET=320" because a liveness SELECT timed
# out under CPU saturation while the guest was in fact healthy (46 GB free, and
# it kept serving afterwards). A liveness probe therefore measures the DRIVER and
# the CPU, not the memory ceiling we care about.
#
# This version:
#   - opens IDLE-but-established backends (each forks, builds relcache/catcache,
#     touches its arena) so the per-backend FOOTPRINT is what scales, not CPU;
#   - a modest churn burst per backend commits overflow, then the session parks;
#   - judges the guest by whether it still answers with a GENEROUS timeout, and
#     records the count reached, so the stop reason is memory, not scheduling.
# ARGS: <step> <max> <settle-seconds>
set -u
STEP="${1:-32}"
MAX="${2:-600}"
SETTLE="${3:-20}"
: "${PGHOST:?set PGHOST}"
export PGPASSWORD="${PGPASSWORD:-postgres}" PGHOST PGUSER=postgres PGDATABASE=postgres
OUT="${OUT:-/tmp/maxbk2.log}"
: > "$OUT"
# Each backend: one churn burst (commits overflow regions), then hold the session.
BURST="${BURST:-30}"
ROWS="${ROWS:-20000}"

echo "MAXBK2 step=$STEP max=$MAX settle=${SETTLE}s burst=$BURST rows=$ROWS" | tee -a "$OUT"

alive() { timeout 90 psql -tAc "SELECT 1" >/dev/null 2>&1; }

n=0
while [ "$n" -lt "$MAX" ]; do
  i=0
  while [ "$i" -lt "$STEP" ]; do
    (
      # burst of churn, then park for the rest of the run holding the backend
      psql -q -v ON_ERROR_STOP=0 -c "
        SELECT count(*) FROM (
          SELECT sum(x) OVER () FROM (
            SELECT (g*7919)%100003 AS x FROM generate_series(1,$ROWS) g ORDER BY 1
          ) s
        ) t" >/dev/null 2>&1
      psql -q -c "SELECT pg_sleep(3600)" >/dev/null 2>&1
    ) &
    i=$((i+1))
  done
  n=$((n+STEP))
  sleep "$SETTLE"
  if ! alive; then
    echo "NOT_ANSWERING_AT=$n" | tee -a "$OUT"
    # Give it a chance: this may be transient CPU saturation, not death.
    sleep 30
    if alive; then
      echo "  (recovered -- was saturation, not death)" | tee -a "$OUT"
    else
      echo "MAXBK2_STOP reached=$n" | tee -a "$OUT"
      break
    fi
  fi
  BK=$(timeout 90 psql -tAc "select count(*) from pg_stat_activity where backend_type='client backend'" 2>/dev/null | tr -d ' ')
  echo "t=$(date +%s) target=$n live=${BK:-?} OK" | tee -a "$OUT"
done
echo "MAXBK2_RESULT reached=$n" | tee -a "$OUT"
pkill -P $$ psql 2>/dev/null
kill $(jobs -p) 2>/dev/null
wait 2>/dev/null
echo MAXBK2_DONE | tee -a "$OUT"
