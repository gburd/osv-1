#!/bin/bash
# Pure connect/disconnect churn (NO transaction) to test whether leak #2 (memory)
# is per-fork (connection) or per-query. Each round opens N connections that do
# nothing but connect and immediately close.
set -u
ROUNDS="${1:-150}"; N="${2:-32}"; H="${3:-192.168.100.2}"
export PGCONNECT_TIMEOUT=10
CONSOLE=$(ls -t /work/pgconsole-run-*.log | head -1)
LOG=/work/churnconn-$(date +%H%M%S).log
echo "CHURNCONN rounds=$ROUNDS N=$N console=$CONSOLE" | tee "$LOG"
for r in $(seq 1 "$ROUNDS"); do
  pids=""
  for c in $(seq 1 "$N"); do
    # connect + immediate disconnect: -c '' with a no-op; forks a backend that exits fast
    psql -h "$H" -U postgres -d demo -qtAc "SELECT 1" >/dev/null 2>&1 &
    pids="$pids $!"
  done
  for p in $pids; do wait "$p"; done
  if [ $((r % 10)) -eq 0 ]; then
    probe=$(grep '^LEAKPROBE ' "$CONSOLE" 2>/dev/null | tail -1)
    echo "ROUND $r | $probe" | tee -a "$LOG"
  fi
done
echo "CHURNCONN done" | tee -a "$LOG"
