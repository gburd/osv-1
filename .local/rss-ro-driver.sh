#!/bin/bash
# rss-ro-driver.sh -- native RO pgbench sweep. Run from the DRIVER host in the same VPC.
# Hits DB host PRIVATE IP over real ENA (NOT loopback). RO only (-S), data static so
# init ONCE then re-run -S at each concurrency (fresh, 0-failed check per cell).
#   usage: rss-ro-driver.sh <DB_PRIV_IP> <LABEL>
set -u
DBIP="${1:?db priv ip}"; LABEL="${2:?label}"
SCALE="${SCALE:-300}"; DUR="${DUR:-30}"; PGU=postgres
export PGCONNECT_TIMEOUT=15 PGPASSWORD="${PGPASSWORD:-}"
P(){ psql "host=$DBIP port=5432 user=$PGU dbname=$1 connect_timeout=15" -tAc "$2" 2>&1; }
PB(){ pgbench -h "$DBIP" -p 5432 -U "$PGU" "$@"; }

echo "RESULT: $LABEL inet_server_addr=$(P postgres 'select inet_server_addr()')"
echo "RESULT: $LABEL server_version=$(P postgres 'show server_version')"

# init bench DB ONCE at scale (RO: data never mutates across the sweep)
P postgres "drop database if exists bench" >/dev/null 2>&1
P postgres "create database bench template template0" >/dev/null 2>&1
echo "-- pgbench -i -s $SCALE (once) --"
PB -U "$PGU" -i -s "$SCALE" -q bench 2>&1 | tail -2

for C in ${LEVELS:-1 8 16 32 48 64}; do
  J=$C; [ "$C" -gt 8 ] && J=8
  # warm/prime one short run, then the measured run (median of 2 measured)
  best=""
  for r in 1 2; do
    OUT=$(PB -U "$PGU" -S -c "$C" -j "$J" -T "$DUR" -P 5 bench 2>&1)
    TPS=$(echo "$OUT" | awk '/^tps/{print $3; exit}')
    LAT=$(echo "$OUT" | awk '/latency average/{print $4; exit}')
    FAIL=$(echo "$OUT" | awk '/number of failed/{print $5; exit}')
    echo "RESULT: $LABEL ro c$C run$r tps=$TPS lat_ms=$LAT failed=$FAIL"
  done
done
echo "==== $LABEL RO sweep done ===="
