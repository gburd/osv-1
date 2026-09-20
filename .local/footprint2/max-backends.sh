#!/bin/bash
# MAX BACKENDS BEFORE OOM -- THE HEADLINE NUMBER. Runs ON THE DRIVER.
#
# Opens churning connections in steps and records the highest backend count the
# guest SUSTAINS before it OOMs or stops answering. Churn is the point: an idle
# connection barely exercises the footprint, so an idle-connection sweep would
# overstate capacity.
#
# Run twice from ONE build for the before/after:
#   BEFORE: guest booted OVF_RECYCLE=0 (churn-proportional, today)
#   AFTER : guest booted OVF_RECYCLE=1 (owning-AS recycling, the fix)
#
# ARGS: <step> <max> <hold-seconds-per-step>
set -u
STEP="${1:-16}"
MAX="${2:-512}"
HOLD="${3:-60}"
: "${PGHOST:?set PGHOST}"
export PGHOST PGUSER="${PGUSER:-postgres}" PGDATABASE="${PGDATABASE:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
OUT="${OUT:-/tmp/maxbk.log}"
ROWS="${ROWS:-50000}"
: > "$OUT"

echo "MAXBK step=$STEP max=$MAX hold=${HOLD}s rows=$ROWS host=$PGHOST" | tee -a "$OUT"

alive() { timeout 20 psql -tAq -c "SELECT 1" >/dev/null 2>&1; }

if ! alive; then echo "FATAL: guest not answering at start" | tee -a "$OUT"; exit 1; fi

LAST_OK=0
n=$STEP
while [ "$n" -le "$MAX" ]; do
  # add STEP more churning sessions (existing ones keep running)
  i=0
  while [ "$i" -lt "$STEP" ]; do
    (
      psql -q -v ON_ERROR_STOP=0 <<'SQL' >/dev/null 2>&1
SELECT sum(x) FROM (
  SELECT (g * 7919) % 100003 AS x FROM generate_series(1, 50000) g ORDER BY 1
) t
\watch 0.01
SQL
    ) &
    i=$((i+1))
  done
  sleep 3
  # Hold at this level, polling liveness; a dead/OOM guest ends the sweep.
  DEADLINE=$(( $(date +%s) + HOLD ))
  DIED=0
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if ! alive; then DIED=1; break; fi
    sleep 5
  done
  if [ "$DIED" = 1 ]; then
    echo "DIED_AT_TARGET=$n LAST_SUSTAINED=$LAST_OK" | tee -a "$OUT"
    break
  fi
  BK=$(timeout 20 psql -tAq -c "SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend'" 2>/dev/null)
  echo "t=$(date +%s) target=$n live_backends=$BK SUSTAINED" | tee -a "$OUT"
  LAST_OK="${BK:-$n}"
  n=$((n+STEP))
done

echo "MAXBK_RESULT last_sustained=$LAST_OK" | tee -a "$OUT"
pkill -P $$ psql 2>/dev/null
kill $(jobs -p) 2>/dev/null
wait 2>/dev/null
echo MAXBK_DONE | tee -a "$OUT"
