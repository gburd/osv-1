#!/bin/bash
# Run ONE cell: N settled reps at one VU level on one arm, with CLIENT-SIDE
# instrumentation so "not driver-limited" is proven rather than assumed.
# Runs ON the driver box.
# ARGS: <arm> <host> <vu> <mode: ro|rw> <secs> <reps>
set -u
ARM=$1; H=$2; VU=$3; MODE=$4; T=$5; REPS=$6
PGB=/usr/lib/postgresql/18/bin
FLAG=""; [ "$MODE" = ro ] && FLAG="-S"
J=$VU; [ "$J" -gt 32 ] && J=32     # never more jobs than clients, cap at 32 of 36 cores
NIC=$(ip -o -4 route show to default | awk '{print $5}')

for r in $(seq 1 $REPS); do
  O=/tmp/cell-$ARM-$MODE-vu$VU-r$r
  CPU0=$(head -1 /proc/stat)
  rx0=$(cat /sys/class/net/$NIC/statistics/rx_bytes); tx0=$(cat /sys/class/net/$NIC/statistics/tx_bytes)
  t0=$(date +%s.%N)
  # -P 10 progress + -r per-statement; --latency-limit is NOT set, so no
  # transaction is skipped and "failed" means a real failure.
  $PGB/pgbench $FLAG -h $H -U postgres -d postgres -c $VU -j $J -T $T -P 10 -r \
    > $O.out 2> $O.err
  RC=$?
  t1=$(date +%s.%N)
  CPU1=$(head -1 /proc/stat)
  rx1=$(cat /sys/class/net/$NIC/statistics/rx_bytes); tx1=$(cat /sys/class/net/$NIC/statistics/tx_bytes)

  TPS=$(awk '/^tps =/{print $3; exit}' $O.out)
  LAT=$(awk '/^latency average/{print $4; exit}' $O.out)
  STD=$(awk '/^latency stddev/{print $4; exit}' $O.out)
  # $5 not $6: the line is "number of failed transactions: 0 (0.000%)", so field 6
  # is the PERCENTAGE in parentheses, which made every cell report
  # failed=(0.000%) instead of a count.  Strip to digits so the 0-failed gate is
  # testable arithmetic rather than a string that is never equal to 0.
  FAILED=$(awk '/number of failed transactions/{print $5; exit}' $O.out | tr -cd '0-9')
  XACT=$(awk '/number of transactions actually processed/{print $6; exit}' $O.out)
  # p99 from the per-interval progress samples: pgbench does not print p99, so
  # report the interval-tps minimum and the latency max across -P 10 samples as
  # an explicitly-labelled interval proxy, plus the reported stddev.
  # pgbench writes -P progress lines to STDERR, not stdout, and the fields are
  # "progress: 10.0 s, 145603.5 tps, lat 0.216 ms stddev 0.503, 0 failed" -- so
  # the tps value PRECEDES the literal "tps" and the lat value FOLLOWS "lat".
  # Reading them from $O.out with the value after "tps" yielded empty strings.
  PMIN=$(awk '/^progress:/{for(i=1;i<=NF;i++) if($i=="tps,"){print $(i-1)}}' $O.err | sort -n | head -1)
  LMAX=$(awk '/^progress:/{for(i=1;i<=NF;i++) if($i=="lat"){print $(i+1)}}' $O.err | sort -n | tail -1)
  PFAIL=$(awk '/^progress:/{s+=$(NF-1)} END{print s+0}' $O.err)
  CLI=$(python3 -c "
a=[int(x) for x in '''$CPU0'''.split()[1:]]
b=[int(x) for x in '''$CPU1'''.split()[1:]]
d=[y-x for x,y in zip(a,b)]; tot=sum(d); busy=tot-d[3]-d[4]
w=$t1-$t0
print(f'{100.0*busy/tot:.1f} {$(nproc)*busy/tot:.2f} {($rx1-$rx0)/w/1e6:.1f} {($tx1-$tx0)/w/1e6:.1f}')")
  set -- $CLI
  echo "REP $ARM $MODE vu$VU r$r tps=$TPS lat_ms=$LAT lat_sd=$STD int_tps_min=$PMIN int_lat_max=$LMAX xact=$XACT failed=${FAILED:-0} progfail=$PFAIL rc=$RC drv_cpu_pct=$1 drv_cores=$2/$(nproc) drv_rx_MBps=$3 drv_tx_MBps=$4"
done
echo "CELL_DONE $ARM $MODE vu$VU"
