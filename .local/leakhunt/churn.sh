#!/bin/bash
# Connection-churn repro for the OSv forked-backend teardown wedge.
# Each round: open N PG connections in parallel, each runs a trivial txn, then
# all disconnect. That forks+reaps N backends per round. Autovacuum is left ON
# (it forks a worker per cycle continuously). Between rounds we grep the newest
# LEAKPROBE line so the two series (round number, leak counters) line up.
#
# Usage: churn.sh <rounds> <conns_per_round> [dbhost]
set -u
ROUNDS="${1:-100}"
N="${2:-32}"
H="${3:-192.168.100.2}"
DB=demo
export PGCONNECT_TIMEOUT=10
LOG=/work/churn-$(date +%H%M%S).log
CONSOLE=$(ls -t /work/pgconsole-run-*.log | head -1)
echo "CHURN start rounds=$ROUNDS N=$N host=$H console=$CONSOLE" | tee "$LOG"

one_conn() {
  # a trivial transaction: BEGIN; a tiny write + read; COMMIT. New backend each time.
  psql -h "$H" -U postgres -d "$DB" -qtAc \
    "BEGIN; INSERT INTO churn(v) VALUES ($1); SELECT count(*) FROM churn WHERE v=$1; COMMIT;" \
    >/dev/null 2>&1
}

t0=$(date +%s)
for r in $(seq 1 "$ROUNDS"); do
  rt0=$(date +%s.%N)
  pids=""
  for c in $(seq 1 "$N"); do
    one_conn "$r" &
    pids="$pids $!"
  done
  ok=0; fail=0
  for p in $pids; do if wait "$p"; then ok=$((ok+1)); else fail=$((fail+1)); fi; done
  rt1=$(date +%s.%N)
  dur=$(echo "$rt1 - $rt0" | bc)
  # newest probe line at this moment
  probe=$(grep '^LEAKPROBE ' "$CONSOLE" 2>/dev/null | tail -1)
  ts=$(grep '^LEAKPROBE_TS ' "$CONSOLE" 2>/dev/null | tail -1)
  now=$(date +%s)
  printf "ROUND %d elapsed=%ds dur=%.2fs ok=%d fail=%d | %s\n" \
    "$r" "$((now-t0))" "$dur" "$ok" "$fail" "$probe" | tee -a "$LOG"
  echo "         $ts" | tee -a "$LOG"
done
echo "CHURN done" | tee -a "$LOG"
