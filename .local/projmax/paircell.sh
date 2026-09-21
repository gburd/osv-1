#!/bin/bash
# Run one matched cell pair (OSv + Linux) at one VU/mode, from the DRIVER box,
# with client-side instrumentation. Fresh boot per cell is the caller's job.
# ARGS: <vu> <mode: ro|rw> <secs> <reps>
set -u
. /home/gburd/ws/osv/.local/projmax/env.sh
VU=$1; MODE=$2; T=$3; REPS=$4
P=/home/gburd/ws/osv/.local/projmax

for ARM in osv lin; do
  if [ "$ARM" = osv ]; then H=$OSVPRIV; else H=$LINUXPRIV; fi
  echo "=== ARM=$ARM VU=$VU MODE=$MODE host=<$ARM-arm>"
  # seed: pgbench -i -s 100, identical both arms, per cell
  ssh $SSHO $DRV "/usr/lib/postgresql/18/bin/pgbench -i -s 100 -h $H -U postgres -d postgres --quiet 2>&1 | tail -2" 2>&1 | tail -2
  ssh $SSHO $DRV "bash /tmp/cell.sh $ARM $H $VU $MODE $T $REPS" 2>&1 | tee -a "$P/cells-raw.txt"
done
echo "PAIR_DONE vu$VU $MODE"
