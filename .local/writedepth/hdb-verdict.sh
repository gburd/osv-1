#!/bin/bash
# HammerDB verdict driver (run FROM the workstation).
# For each (spin, VU): boot PG guest with OSV_IDLE_SPIN=spin, wait PG-ready,
# sample metal host CPU (guest qemu vCPU busy%) during the run, run the timed
# TCL from the driver box, capture NOPM. Tear down between cells.
# The metal-CPU sample distinguishes spin-cycles from query-cycles: if a spin
# value raises NOPM AND host CPU is doing useful work -> real win; if CPU high
# but NOPM flat/down -> spin taxing the workload.
set -uo pipefail
. /home/gburd/ws/osv/.local/writedepth/env.sh
LOCAL=/home/gburd/ws/osv/.local/writedepth/hdb
mkdir -p "$LOCAL"
PGH=$METALPRIV
SPINS="${SPINS:-10000 100000 500000}"
VUS="${VUS:-16 32}"

pg_ready() {  # wait until PG answers on the guest via DNAT
  for i in $(seq 1 60); do
    if ssh $SSHO $DRV "PGPASSWORD=postgres psql -h $PGH -U postgres -p 5432 -d postgres -tAc 'select 1' 2>/dev/null" | grep -q 1; then return 0; fi
    sleep 5
  done
  return 1
}

boot_guest() {  # $1=spin
  local SPIN="$1"
  ssh $SSHO $METAL "cd /work && POOL_NUM_QUEUES=8 nohup bash pg-boot.sh run --env=OSV_IDLE_SPIN=$SPIN >/work/pgrun-spin$SPIN.out 2>&1 & echo started"
  sleep 3
}
kill_guest() { ssh $SSHO $METAL "sudo pkill -9 -f qemu-system-x86 2>/dev/null; sleep 3"; }

echo "### HammerDB verdict  spins=[$SPINS] VUs=[$VUS]  PGH=$PGH"
for SPIN in $SPINS; do
  echo "===== boot guest spin=$SPIN ====="
  kill_guest
  boot_guest "$SPIN"
  if ! pg_ready; then echo "SPIN=$SPIN PG_NOT_READY"; ssh $SSHO $METAL "tail -15 /work/pgrun-spin$SPIN.out"; continue; fi
  echo "PG ready (spin=$SPIN)"
  for VU in $VUS; do
    TAG="spin${SPIN}_vu${VU}"
    echo "--- cell $TAG ---"
    # sample metal total CPU busy% during the run (mpstat 5s x 90 = ~7.5min covers rampup+dur)
    ssh $SSHO $METAL "nohup sh -c 'mpstat 5 90 > /work/cpu-$TAG.txt 2>&1' >/dev/null 2>&1 & echo cpu_sampling"
    # run the timed TCL on the driver
    ssh $SSHO $DRV "PGH=$PGH VU=$VU /opt/HammerDB-6.0/hammerdbcli auto /tmp/hdb-run.tcl >/tmp/hdb-$TAG.log 2>&1; echo RUN_RC=\$?"
    # collect NOPM/TPM
    ssh $SSHO $DRV "grep -E 'System achieved|NOPM|TPM|TEST RESULT' /tmp/hdb-$TAG.log 2>/dev/null | tail -4" | tee "$LOCAL/$TAG.result.txt"
    scp $SSHO "$DRV:/tmp/hdb-$TAG.log" "$LOCAL/" 2>/dev/null
    # metal CPU median busy
    ssh $SSHO $METAL "awk '/all/{u=100-\$NF; s+=u; n++} END{if(n)printf \"metal_cpu_busy_mean=%.1f%% samples=%d\n\", s/n, n}' /work/cpu-$TAG.txt 2>/dev/null" | tee -a "$LOCAL/$TAG.result.txt"
  done
done
kill_guest
echo "HDB_VERDICT_DONE"
