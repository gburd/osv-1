#!/bin/bash
# HammerDB TPROC-C build + timed sweep, external driver.
# ARGS: build <host>          -- build the 200-warehouse schema
#       run   <host> <vu> <tag>  -- one timed run
set -euo pipefail
HDB=/opt/HammerDB-6.0
H="$2"
MODE="$1"
cd $HDB

if [ "$MODE" = build ]; then
cat > /tmp/build.tcl <<EOF
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
diset tpcc pg_count_ware 200
diset tpcc pg_num_vu 32
diset tpcc pg_partition false
buildschema
waittocomplete
EOF
exec $HDB/hammerdbcli auto /tmp/build.tcl
fi

VU="$3"; TAG="$4"
# TRAP: rotate xtprof per run or a 64-vu run reports 160 vusers
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
# TRAP: runtimer is deprecated in 6.0 and returns immediately -> vudestroy fires
# before vusers drain and reports failure on a healthy guest. Poll vucomplete.
# CAP at 240s: the timed run is fixed at 7min; if vucomplete has not flipped 4min after,
# the timing-gather has hung (a HammerDB 6.0 artifact) -- force vudestroy so the cell
# still yields its NOPM instead of wedging the sweep for 25min.
set t 0
while {\$t < 360} { if {[vucomplete]} { break } ; after 1000 ; incr t }
puts "VUCOMPLETE_AFTER \$t s"
vudestroy
after 5000
quit
EOF
$HDB/hammerdbcli auto /tmp/run-$TAG.tcl 2>&1 | tee /tmp/hdb-$TAG.log
cp -f /tmp/hdbxtprofile.log /tmp/xtprof-$TAG.log 2>/dev/null || true
grep -E 'NOPM|TEST RESULT|VUCOMPLETE_AFTER|vuser.*FATAL|Error' /tmp/hdb-$TAG.log | tail -10
