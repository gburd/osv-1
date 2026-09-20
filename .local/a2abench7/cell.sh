#!/bin/bash
# One benchmark cell: start the connect probe, run HammerDB, collect instruments.
# ARGS: <guest-ip-via-metal> <vu> <tag> <metal-ssh-target>
set -uo pipefail
H="$1"; VU="$2"; TAG="$3"
DUR=420   # rampup 2 + duration 5 = 7 min

# probe alone during the timed window: start it after rampup, run through duration
( sleep 130; PSQL=psql python3 /tmp/probe.py "$H" 5432 300 /tmp/probe-$TAG.json > /tmp/probe-$TAG.out 2>&1 ) &
PROBEPID=$!

bash /tmp/hdb.sh run "$H" "$VU" "$TAG" > /tmp/cell-$TAG.log 2>&1
wait $PROBEPID 2>/dev/null

echo "=== $TAG ==="
grep -E 'TEST RESULT|System achieved' /tmp/cell-$TAG.log | tail -2
cat /tmp/probe-$TAG.json 2>/dev/null
