#!/bin/bash
# CHURN DISCRIMINATOR -- runs ON THE DRIVER against the OSv guest.
#
# Distinguishes our hypothesis from the brief's original framing:
#   churn-proportional : an IDLE backend costs LITTLE; footprint grows with
#                        per-backend allocation churn, not with live heap.
#   fixed-per-fork     : idle and busy backends cost the SAME.
#
# Three arms at the SAME backend count (so any fixed per-fork cost is identical
# in all three) and the same wall time. The only variable is how much each
# backend CHURNS:
#   IDLE  : connect, one trivial query, then hold the session idle.
#   LIGHT : connect, low-rate churn.
#   HEAVY : connect, continuous per-query MemoryContext churn, small live result.
# Read FPTOT ovfcommit_MB / ovflive_MB off the guest console after each arm.
#
# ARGS: <arm: idle|light|heavy> <nconn> <seconds>
set -u
ARM="${1:-heavy}"
N="${2:-32}"
SECS="${3:-120}"
: "${PGHOST:?set PGHOST to the guest}"
export PGHOST PGUSER="${PGUSER:-postgres}" PGDATABASE="${PGDATABASE:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
OUT=/tmp/churn-$ARM-$N.log
: > "$OUT"

case "$ARM" in
  idle)  ROWS=1;     SLEEP=0 ;;      # one trivial query then park
  light) ROWS=1000;  SLEEP=1 ;;      # ~1 churn cycle/sec
  heavy) ROWS=50000; SLEEP=0 ;;      # continuous churn
  *) echo "bad arm $ARM"; exit 2 ;;
esac

echo "ARM=$ARM N=$N SECS=$SECS ROWS=$ROWS SLEEP=$SLEEP" | tee -a "$OUT"

# One psql per connection, each holding ONE session for the whole window, so the
# backend count is FIXED at N in every arm (isolates churn from fork count).
for i in $(seq 1 "$N"); do
  (
    if [ "$ARM" = idle ]; then
      # Establish the backend, one trivial query, then hold it open doing
      # nothing: a backend that forked and never churns.
      psql -q -c "SELECT 1" -c "SELECT pg_sleep($SECS)" >/dev/null 2>&1
    else
      # Churn inside ONE session (\watch keeps the same backend, so we measure
      # per-backend churn, not repeated fork cost).
      psql -q -v ON_ERROR_STOP=0 <<SQL >/dev/null 2>&1
\\timing off
SELECT sum(x) FROM (
  SELECT (g * 7919) % 100003 AS x
  FROM generate_series(1, $ROWS) g ORDER BY 1
) t
\\watch $( [ "$SLEEP" = 0 ] && echo 0.01 || echo "$SLEEP" )
SQL
    fi
  ) &
done
CHURN_PIDS=$!

# Report the live backend count every 15s so the arms are verifiably comparable.
END=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt "$END" ]; do
  BK=$(psql -tAq -c "SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend'" 2>/dev/null)
  echo "t=$(date +%s) backends=$BK" | tee -a "$OUT"
  sleep 15
done
# \watch runs forever; stop the arm cleanly at the deadline.
pkill -P $$ psql 2>/dev/null
kill $(jobs -p) 2>/dev/null
wait 2>/dev/null
echo "CHURN_ARM_DONE $ARM" | tee -a "$OUT"
