#!/bin/bash
# bench-windows.sh -- run against the already-serving guest at 192.168.100.2.
# Captures cumulative RXPROF/WAKEPROF snapshots bracketing each load window so
# per-window HOP deltas can be computed. bench DB must already exist (C locale).
set -u
G=192.168.100.2; export PGPASSWORD=
PGB=/usr/bin/pgbench
LOG=/tmp/osv.log

snap() { grep -aE "^RXPROF passes|^WAKEPROF samples" "$LOG" | tail -2; }

echo "RESULT inet_server_addr=$(psql "host=$G port=5432 user=postgres dbname=postgres" -tAc "select inet_server_addr()" 2>&1)"

# warm
$PGB -h $G -p 5432 -U postgres -S -c 8 -j 8 -T 6 bench >/dev/null 2>&1
sleep 6

for C in 8 32; do
  J=$C; [ "$C" -gt 8 ] && J=8
  echo "======== WINDOW c$C (DUR=${DUR:-30}s) ========"
  echo "--- BEFORE c$C ---"; snap
  OUT=$($PGB -h $G -p 5432 -U postgres -S -c "$C" -j "$J" -T "${DUR:-30}" bench 2>&1)
  TPS=$(echo "$OUT"|awk '/^tps/{print $3;exit}'); LAT=$(echo "$OUT"|awk '/latency average/{print $4;exit}')
  echo "RESULT: RO c$C tps=$TPS lat_ms=$LAT"
  sleep 7   # let a 5s dump land fully after the window
  echo "--- AFTER c$C (full) ---"
  grep -aE "^RXPROF |^WAKEPROF " "$LOG" | tail -14
done
echo "BENCH_WINDOWS_DONE"
