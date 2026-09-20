#!/bin/bash
# One benchmark cell WITH the pg_stat_activity wait-event histogram (the deliverable).
# Runs on the DRIVER. Starts probe + wait-sampler, runs HammerDB, collects.
# ARGS: <guest-ip-via-metal> <vu> <tag>
# The wait sampler runs for the full ~5-min timed window (starts after rampup).
set -uo pipefail
H="$1"; VU="$2"; TAG="$3"

# rampup is 2 min; timed duration is 5 min. Start instruments after rampup (~125s),
# run them for ~300s to cover the whole measurement window.
( sleep 125; PSQL=psql python3 /tmp/probe.py "$H" 5432 300 /tmp/probe-$TAG.json > /tmp/probe-$TAG.out 2>&1 ) &
PROBEPID=$!
( sleep 125; PSQL=psql python3 /tmp/waitsample.py "$H" 5432 300 /tmp/wait-raw-$TAG.ndjson /tmp/wait-hist-$TAG.json > /tmp/wait-$TAG.out 2>&1 ) &
WAITPID=$!

bash /tmp/hdb.sh run "$H" "$VU" "$TAG" > /tmp/cell-$TAG.log 2>&1
wait $PROBEPID 2>/dev/null
wait $WAITPID 2>/dev/null

echo "=== $TAG ==="
grep -E 'TEST RESULT|System achieved' /tmp/cell-$TAG.log | tail -2
echo "--- probe ---"; cat /tmp/probe-$TAG.json 2>/dev/null
echo "--- wait histogram coarse ---"; head -c 4000 /tmp/wait-hist-$TAG.json 2>/dev/null
