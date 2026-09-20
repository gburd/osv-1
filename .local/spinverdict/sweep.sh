#!/bin/bash
# spinverdict sweep driver (run FROM the workstation).
# For each (spin, VU, rep): boot OSv PG guest with OSV_IDLE_SPIN=spin (imports the
# ALREADY-SEEDED 200wh pool), wait PG-ready, sample metal host CPU (mpstat) during the
# run, run the timed HammerDB TCL from the driver, capture NOPM. Checkpoint+teardown
# between spin values (idle checkpoint -> next boot replay ~0; skipping it = 4min crash
# recovery per boot).
#
# vCPU-util DISCRIMINATOR: mpstat on metal gives total host CPU busy% + usr/sys split
# during each run. Idle-spin runs in cpu::do_idle (busy-polling) -> shows as host CPU with
# NO matching NOPM rise. Query work -> host CPU that DOES track NOPM. Decision:
#   spin lifts NOPM and CPU-rise tracks NOPM  -> useful work (real transfer/win)
#   NOPM flat/down while CPU rises            -> idle-spin stealing query cycles (tax)
set -uo pipefail
. /home/gburd/ws/osv/.local/spinverdict/env.sh
LOCAL=/home/gburd/ws/osv/.local/spinverdict/results
mkdir -p "$LOCAL"
PGH=$METALPRIV
SPINS="${SPINS:-10000 100000 500000}"
VUS="${VUS:-16 32}"
REPS="${REPS:-1 2}"      # r1 cold (voided in analysis), r2 settled. add 3 for more.
RAMP="${RAMP:-2}"; DUR="${DUR:-3}"

pg_ready() {
  for i in $(seq 1 90); do
    if ssh $SSHO $DRV "PGPASSWORD=postgres psql -h $PGH -U postgres -p 5432 -d tpcc -tAc 'select 1' 2>/dev/null" | grep -q 1; then return 0; fi
    sleep 5
  done
  return 1
}
boot_guest() { ssh $SSHO $METAL "cd /work && POOL_NUM_QUEUES=8 nohup bash pg-boot.sh run --env=OSV_IDLE_SPIN=$1 >/work/pgrun-spin$1.out 2>&1 & echo started"; sleep 3; }
checkpoint_db() { ssh $SSHO $DRV "PGPASSWORD=postgres psql -h $PGH -U postgres -p 5432 -d tpcc -c 'checkpoint' -c 'checkpoint' 2>&1 | tail -1" 2>/dev/null || true; }
kill_guest() { sleep 15; checkpoint_db; sleep 3; checkpoint_db; ssh $SSHO $METAL "sudo pkill -9 -f qemu-system-x86 2>/dev/null; sleep 5"; }

echo "### spinverdict sweep  spins=[$SPINS] VUs=[$VUS] reps=[$REPS] ramp=$RAMP dur=$DUR  PGH=$PGH"
for SPIN in $SPINS; do
  echo "===== boot guest spin=$SPIN ====="
  kill_guest
  boot_guest "$SPIN"
  if ! pg_ready; then echo "SPIN=$SPIN PG_NOT_READY"; ssh $SSHO $METAL "ls -t /work/pgconsole-run-*.log|head -1|xargs tail -15"; continue; fi
  echo "PG ready (spin=$SPIN)"
  for VU in $VUS; do
    RUNSECS=$(( (RAMP + DUR) * 60 + 60 )); SAMP=$(( RUNSECS / 3 ))
    for REP in $REPS; do
      RTAG="spin${SPIN}_vu${VU}_r${REP}"
      echo "--- cell $RTAG ---"
      ssh $SSHO $METAL "nohup sh -c 'mpstat 3 $SAMP > /work/cpu-$RTAG.txt 2>&1' >/dev/null 2>&1 & echo cpu_sampling"
      ssh $SSHO $DRV "RAMP=$RAMP DUR=$DUR bash /tmp/hdb.sh run $PGH $VU $RTAG >/tmp/hdb-$RTAG.log 2>&1; echo RUN_RC=\$?"
      ssh $SSHO $DRV "grep -E 'TEST RESULT|System achieved|VUCOMPLETE_AFTER' /tmp/hdb-$RTAG.log 2>/dev/null | tail -3" | tee "$LOCAL/$RTAG.result.txt"
      scp $SSHO "$DRV:/tmp/hdb-$RTAG.log" "$LOCAL/" 2>/dev/null
      scp $SSHO "$METAL:/work/cpu-$RTAG.txt" "$LOCAL/" 2>/dev/null
      ssh $SSHO $METAL "awk '/all/{u=100-\$NF; s+=u; n++; usr+=\$3; sys+=\$5} END{if(n)printf \"metal_cpu_busy_mean=%.1f%% usr=%.1f sys=%.1f samples=%d\n\", s/n, usr/n, sys/n, n}' /work/cpu-$RTAG.txt 2>/dev/null" | tee -a "$LOCAL/$RTAG.result.txt"
    done
  done
done
kill_guest
echo "SWEEP_DONE"
