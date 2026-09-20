#!/bin/bash
# VU32 VERDICT driver: the decisive M1 transfer question.
# Does raising OSV_IDLE_SPIN rescue the VU32 collapse (~9k NOPM baseline)?
# Each rep = FRESH guest boot + hardened quiesce (2 consecutive sub-1s checkpoints) + ONE
# timed HammerDB run + mpstat discriminator. Fresh boot per rep kills the cumulative-
# degradation confound (throughput fell 169k->0 across runs on one boot).
set -uo pipefail
. /home/gburd/ws/osv/.local/spinverdict/env.sh
LOCAL=/home/gburd/ws/osv/.local/spinverdict/verdict32
mkdir -p "$LOCAL"
PGH=$METALPRIV
SPINS="${SPINS:-10000 100000 500000}"
VU="${VU:-32}"
REPS="${REPS:-1 2 3}"
RAMP="${RAMP:-2}"; DUR="${DUR:-3}"

pg_ready() {
  # tolerate up to ~8min: a fresh boot after a busy run replays torn WAL (~4min) before
  # accepting connections. Timing out here throws away the whole cell.
  for i in $(seq 1 96); do
    ssh $SSHO $DRV "PGPASSWORD=postgres psql -h $PGH -U postgres -p 5432 -d tpcc -tAc 'select 1' 2>/dev/null" | grep -q 1 && return 0
    sleep 5
  done; return 1
}
# hardened quiesce: 2 spaced checkpoints on the freshly-booted (idle) DB so the run starts
# from a flushed, bgwriter-caught-up state. Fresh boot already recovered+checkpointed, so this
# mainly guarantees no residual dirty pages from recovery.
quiesce() {
  for pass in 1 2; do
    ssh $SSHO $DRV "PGPASSWORD=postgres psql -h $PGH -U postgres -p 5432 -d tpcc -c 'checkpoint' 2>&1 | tail -1" 2>/dev/null
    sleep 5
  done
}
boot_guest() { ssh $SSHO $METAL "cd /work && POOL_NUM_QUEUES=8 nohup bash pg-boot.sh run --env=OSV_IDLE_SPIN=$1 >/work/pgrun-v$1.out 2>&1 & echo started"; sleep 3; }
kill_guest() {
  # settle then flush: let the just-finished run drain, checkpoint, wait for the flush, checkpoint
  # again, THEN kill. This keeps the next boot's WAL replay small (else ~4min crash recovery).
  sleep 20
  ssh $SSHO $DRV "PGPASSWORD=postgres psql -h $PGH -U postgres -p 5432 -d tpcc -c 'checkpoint' 2>&1 | tail -1" 2>/dev/null || true
  sleep 15
  ssh $SSHO $DRV "PGPASSWORD=postgres psql -h $PGH -U postgres -p 5432 -d tpcc -c 'checkpoint' 2>&1 | tail -1" 2>/dev/null || true
  sleep 5
  ssh $SSHO $METAL "sudo pkill -9 -f qemu-system-x86 2>/dev/null; sleep 5"
}

echo "### VU32 VERDICT  spins=[$SPINS] VU=$VU reps=[$REPS] ramp=$RAMP dur=$DUR  (fresh boot per rep)"
for SPIN in $SPINS; do
  for REP in $REPS; do
    RTAG="v_spin${SPIN}_vu${VU}_r${REP}"
    echo "===== $RTAG : fresh boot ====="
    kill_guest
    boot_guest "$SPIN"
    if ! pg_ready; then echo "$RTAG PG_NOT_READY"; ssh $SSHO $METAL "ls -t /work/pgconsole-run-*.log|head -1|xargs tail -12"; continue; fi
    # confirm warehouse=200 (DB intact) and quiesce
    WH=$(ssh $SSHO $DRV "PGPASSWORD=postgres psql -h $PGH -U postgres -p 5432 -d tpcc -tAc 'select count(*) from warehouse' 2>/dev/null" 2>/dev/null)
    echo "  warehouse=$WH"
    quiesce
    RUNSECS=$(( (RAMP + DUR) * 60 )); SAMP=$(( RUNSECS / 3 ))
    ssh $SSHO $METAL "nohup sh -c 'mpstat 3 $SAMP > /work/cpu-$RTAG.txt 2>&1' >/dev/null 2>&1 & echo cpu_sampling"
    ssh $SSHO $DRV "RAMP=$RAMP DUR=$DUR bash /tmp/hdb.sh run $PGH $VU $RTAG >/tmp/hdb-$RTAG.log 2>&1; echo RUN_RC=\$?"
    ssh $SSHO $DRV "grep -E 'TEST RESULT|VUCOMPLETE_AFTER' /tmp/hdb-$RTAG.log 2>/dev/null | tail -2" | tee "$LOCAL/$RTAG.result.txt"
    scp $SSHO "$DRV:/tmp/hdb-$RTAG.log" "$LOCAL/" 2>/dev/null
    scp $SSHO "$METAL:/work/cpu-$RTAG.txt" "$LOCAL/" 2>/dev/null
    ssh $SSHO $METAL "awk '/all/{u=100-\$NF; s+=u; n++; usr+=\$3; sys+=\$5} END{if(n)printf \"metal_cpu_busy_mean=%.1f%% usr=%.1f sys=%.1f samples=%d\n\", s/n, usr/n, sys/n, n}' /work/cpu-$RTAG.txt 2>/dev/null" | tee -a "$LOCAL/$RTAG.result.txt"
  done
done
kill_guest
echo "VERDICT32_DONE"
