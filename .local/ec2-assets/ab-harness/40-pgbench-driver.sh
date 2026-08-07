#!/bin/bash
# 40-pgbench-driver.sh -- run from the DRIVER host. IDENTICAL invocation for A and B.
# Hits the DB host's PRIVATE IP:5432 (DNAT -> guest) so PG is reached over the REAL
# NIC, NOT loopback (verified via inet_server_addr()).
#   usage: 40-pgbench-driver.sh <DB_HOST_PRIV_IP> <label>   e.g. ... 172.31.5.69 OSv
set -u
DBIP="${1:?db host private ip}"
LABEL="${2:?label OSv|Linux}"
SCALE="${SCALE:-20}"
DUR="${DUR:-30}"
PGU=postgres
export PGCONNECT_TIMEOUT=10
P() { PGPASSWORD=osv psql "host=$DBIP port=5432 user=$PGU dbname=$1" -tAc "$2" 2>&1; }
PB() { PGPASSWORD=osv pgbench "$@"; }

echo "==== DRIVER A/B: label=$LABEL db=$DBIP scale=$SCALE dur=${DUR}s ===="
# 0) prove NOT loopback: server address as PG sees the client's connection
echo "RESULT: $LABEL inet_server_addr=$(P postgres "select inet_server_addr()")"
echo "RESULT: $LABEL server_version=$(P postgres "show server_version")"

# 1) create the bench DB (idempotent) and init at fixed scale
P postgres "drop database if exists bench" >/dev/null
P postgres "create database bench" >/dev/null
echo "-- pgbench -i -s $SCALE --"
PB -h "$DBIP" -p 5432 -U "$PGU" -i -s "$SCALE" bench 2>&1 | tail -2

# 2) RW (TPC-B) + RO (-S) at the concurrency ladder that WEDGED under slirp
for MODE in rw ro; do
  FLAG=""; [ "$MODE" = ro ] && FLAG="-S"
  for C in ${LEVELS:-1 8 16 32 64}; do
    P postgres "drop database if exists bench" >/dev/null 2>&1
    P postgres "create database bench template template0" >/dev/null 2>&1
    PB -h "$DBIP" -p 5432 -U "$PGU" -i -s "${SCALE:-100}" -q bench >/dev/null 2>&1
    J=$C; [ "$C" -gt 8 ] && J=8
    OUT=$(PB -h "$DBIP" -p 5432 -U "$PGU" $FLAG -c "$C" -j "$J" -T "${DUR:-30}" bench 2>&1)
    TPS=$(echo "$OUT" | awk '/^tps/{print $3; exit}')
    LAT=$(echo "$OUT" | awk '/latency average/{print $4; exit}')
    FAIL=$(echo "$OUT" | awk '/number of failed/{print $5; exit}')
    echo "RESULT: $LABEL $MODE c$C tps=$TPS lat_ms=$LAT failed=$FAIL"
  done
done
echo "==== DRIVER A/B done: $LABEL ===="
