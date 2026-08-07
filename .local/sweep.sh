#!/bin/bash
# sweep.sh -- full RO c1..c64 sweep against the serving guest. bench DB pre-exists (C locale).
set -u
G=192.168.100.2; export PGPASSWORD=
PGB=/usr/bin/pgbench
$PGB -h $G -p 5432 -U postgres -S -c 8 -j 8 -T 5 bench >/dev/null 2>&1
for C in ${LEVELS:-1 2 4 8 16 32 48 64}; do
  J=$C; [ "$C" -gt 8 ] && J=8
  OUT=$($PGB -h $G -p 5432 -U postgres -S -c "$C" -j "$J" -T "${DUR:-20}" bench 2>&1)
  TPS=$(echo "$OUT"|awk '/^tps/{print $3;exit}'); LAT=$(echo "$OUT"|awk '/latency average/{print $4;exit}')
  echo "RESULT: RO c$C tps=$TPS lat_ms=$LAT"
done
echo "SWEEP_DONE"
