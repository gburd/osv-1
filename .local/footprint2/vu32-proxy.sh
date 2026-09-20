#!/bin/bash
# VU32-PROXY throughput A/B.
#
# HONEST SCOPE: this is NOT HammerDB TPC-C NOPM. HammerDB is not installed on the
# driver and no TPC-C schema exists in the guest (only postgres/demo); building a
# 200-warehouse schema costs more budget than remains. So this CANNOT answer the
# VU32 median-NOPM-vs-Linux question, and no number here may be compared to the
# 205k/284k NOPM figures in A2A-FINAL-VERDICT.md.
#
# What it CAN do cheaply and defensibly: at the same concurrency the VU32 cell
# uses, measure whether the footprint fix changes throughput AND whether memory
# pressure is even present. The VU32 hypothesis is a mechanism claim -- per-backend
# footprint -> memory pressure -> reclaim churn -> lost throughput. If free memory
# is high and reclaim absent in BOTH arms, memory pressure is NOT what limits this
# workload at 32 clients, which is evidence about the hypothesis without a NOPM.
#
# ARGS: <clients> <seconds>   env: PGHOST
set -u
C="${1:-32}"
SECS="${2:-120}"
: "${PGHOST:?set PGHOST}"
export PGPASSWORD="${PGPASSWORD:-postgres}" PGHOST PGUSER=postgres PGDATABASE=postgres

if command -v pgbench >/dev/null 2>&1; then
  echo "=== pgbench: init scale 50 if absent ==="
  psql -tAc "SELECT 1 FROM pg_class WHERE relname='pgbench_accounts'" 2>/dev/null | grep -q 1 \
    || pgbench -i -s 50 -q 2>&1 | tail -3
  echo "=== pgbench run clients=$C duration=${SECS}s ==="
  pgbench -c "$C" -j 8 -T "$SECS" -P 15 2>&1 | tail -20
else
  echo "pgbench NOT available; psql tx loop fallback"
  psql -q -c "CREATE TABLE IF NOT EXISTS t32(id int primary key, v bigint)" \
       -c "INSERT INTO t32 SELECT g,0 FROM generate_series(0,99999) g ON CONFLICT DO NOTHING" >/dev/null 2>&1
  END=$(( $(date +%s) + SECS ))
  for i in $(seq 1 "$C"); do
    (
      n=0
      while [ "$(date +%s)" -lt "$END" ]; do
        psql -q -tAc "UPDATE t32 SET v=v+1 WHERE id=(random()*99999)::int" >/dev/null 2>&1
        n=$((n+1))
      done
      echo "$n" > "/tmp/vu32count.$i"
    ) &
  done
  wait 2>/dev/null
  TOT=$(cat /tmp/vu32count.* 2>/dev/null | paste -sd+ - | bc)
  rm -f /tmp/vu32count.* 2>/dev/null
  echo "VU32PROXY clients=$C secs=$SECS total_tx=${TOT:-0} tps=$(echo "scale=1; ${TOT:-0}/$SECS" | bc)"
fi
echo VU32PROXY_DONE
