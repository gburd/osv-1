#!/bin/bash
# Hardened quiesce: require TWO consecutive sub-1s CHECKPOINTs before returning.
# A single fast checkpoint can be a false-quiesce (see zilab VOID r1) if a dirty
# backlog remains after a slow one. ARGS: <host>
set -uo pipefail
H="$1"
Q=/tmp/quiesce.sql
cat > $Q <<'SQL'
\timing on
CHECKPOINT;
SQL
prev_fast=0
for i in $(seq 1 30); do
  # measure a CHECKPOINT wall time via \timing
  T=$(PGCONNECT_TIMEOUT=30 psql -h "$H" -U postgres -d tpcc -f $Q 2>&1 | grep -oiE "Time: [0-9.]+ ms" | grep -oE "[0-9.]+" | head -1)
  [ -z "$T" ] && T=999999
  MS=$(printf "%.0f" "$T")
  echo "  checkpoint $i: ${MS} ms"
  if [ "$MS" -lt 1000 ]; then
    if [ "$prev_fast" -eq 1 ]; then
      echo "  QUIESCED (two consecutive sub-1s checkpoints)"
      exit 0
    fi
    prev_fast=1
  else
    prev_fast=0
  fi
  sleep 3
done
echo "  WARN: quiesce did not reach two consecutive sub-1s checkpoints in 30 tries"
exit 1
