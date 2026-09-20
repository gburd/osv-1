#!/bin/bash
# One benchmark cell for the fsync A/B.
#   quiesce (2x sub-1s CHECKPOINT) -> start probe+waithist in the timed window ->
#   run HammerDB timed (rampup 2 + duration 5) -> collect NOPM / NEWORD p99 /
#   num_timed / num_requested / probe / wait histogram.
# ARGS: <host> <vu> <tag>
set -uo pipefail
H="$1"; VU="$2"; TAG="$3"
HDB=/opt/HammerDB-6.0

echo "=== QUIESCE before $TAG ==="
bash /tmp/quiesce.sh "$H" | tee /tmp/quiesce-$TAG.log
QRC=${PIPESTATUS[0]}
if [ "$QRC" != "0" ]; then echo "QUIESCE FAILED for $TAG -- cell result may be VOID"; fi

# instruments run ALONE inside the timed window: rampup=2min, so start at +130s,
# sample for 300s (through the 5-min measured window).
( sleep 130; PSQL=psql python3 /tmp/probe.py "$H" 5432 300 /tmp/probe-$TAG.json > /tmp/probe-$TAG.out 2>&1 ) &
PROBEPID=$!
( sleep 130; python3 /tmp/waithist.py "$H" 300 /tmp/waithist-$TAG.json > /tmp/waithist-$TAG.out 2>&1 ) &
WHPID=$!
# driver-CPU sampler (parent caution: at VU64 make sure the c5.2xlarge driver is not the bottleneck).
# mpstat over the 300s window: report idle%; if driver idle is low the VU numbers are driver-bound.
( sleep 130; mpstat 30 10 > /tmp/drvcpu-$TAG.txt 2>&1 ) &
DRVCPUPID=$!

# HammerDB timed run
rm -f /tmp/hdbxtprofile.log
cat > /tmp/run-$TAG.tcl <<EOF
dbset db pg
dbset bm TPC-C
diset connection pg_host $H
diset connection pg_port 5432
diset tpcc pg_superuser postgres
diset tpcc pg_superuserpass postgres
diset tpcc pg_defaultdbase postgres
diset tpcc pg_user tpcc
diset tpcc pg_pass tpcc
diset tpcc pg_dbase tpcc
diset tpcc pg_driver timed
diset tpcc pg_rampup 2
diset tpcc pg_duration 5
diset tpcc pg_allwarehouse true
diset tpcc pg_timeprofile true
diset tpcc pg_total_iterations 100000000
loadscript
vuset vu $VU
vuset logtotemp 1
vuset showoutput 1
vucreate
vurun
set t 0
while {\$t < 1500} { if {[vucomplete]} { break } ; after 1000 ; incr t }
puts "VUCOMPLETE_AFTER \$t s"
vudestroy
after 5000
quit
EOF
$HDB/hammerdbcli auto /tmp/run-$TAG.tcl 2>&1 | tee /tmp/hdb-$TAG.log
cp -f /tmp/hdbxtprofile.log /tmp/xtprof-$TAG.log 2>/dev/null || true

wait $PROBEPID 2>/dev/null
wait $WHPID 2>/dev/null
wait $DRVCPUPID 2>/dev/null

echo "=== RESULT $TAG ==="
grep -aE "TEST RESULT|System achieved|VUCOMPLETE_AFTER" /tmp/hdb-$TAG.log | tail -3
echo "--- NEWORD percentiles (xtprofile) ---"
grep -aiE "NEWORD|neworder" /tmp/xtprof-$TAG.log 2>/dev/null | tail -5
echo "--- num_timed / num_requested ---"
grep -aiE "num_timed|num_requested|timed transactions" /tmp/hdb-$TAG.log 2>/dev/null | tail -5
echo "--- probe ---"; cat /tmp/probe-$TAG.json 2>/dev/null
echo "--- wait histogram ---"; cat /tmp/waithist-$TAG.json 2>/dev/null
