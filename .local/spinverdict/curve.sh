#!/bin/bash
# FRESH-BOOT VU CURVE: the reframe's real test. Does OSv still decline VU8->VU16->VU32->VU64
# once run-order contamination is removed (fresh guest boot + quiesce per cell)?
# spin=10000 (baseline default). Each (VU,rep) = its OWN fresh boot.
set -uo pipefail
. /home/gburd/ws/osv/.local/spinverdict/env.sh
LOCAL=/home/gburd/ws/osv/.local/spinverdict/curve
mkdir -p "$LOCAL"
PGH=$METALPRIV
SPIN="${SPIN:-10000}"
VUS="${VUS:-8 16 32 64}"
REPS="${REPS:-1 2}"
RAMP="${RAMP:-2}"; DUR="${DUR:-3}"

pg_ready() { for i in $(seq 1 96); do ssh $SSHO $DRV "PGPASSWORD=postgres psql -h $PGH -U postgres -p 5432 -d tpcc -tAc 'select 1' 2>/dev/null" | grep -q 1 && return 0; sleep 5; done; return 1; }
quiesce() { for p in 1 2; do ssh $SSHO $DRV "PGPASSWORD=postgres psql -h $PGH -U postgres -p 5432 -d tpcc -c 'checkpoint' 2>&1 | tail -1" 2>/dev/null; sleep 5; done; }
boot_guest() { ssh $SSHO $METAL "cd /work && POOL_NUM_QUEUES=8 nohup bash pg-boot.sh run --env=OSV_IDLE_SPIN=$1 >/work/pgrun-c$1.out 2>&1 & echo started"; sleep 3; }
kill_guest() {
  sleep 20
  ssh $SSHO $DRV "PGPASSWORD=postgres psql -h $PGH -U postgres -p 5432 -d tpcc -c 'checkpoint' 2>&1 | tail -1" 2>/dev/null || true
  sleep 15
  ssh $SSHO $DRV "PGPASSWORD=postgres psql -h $PGH -U postgres -p 5432 -d tpcc -c 'checkpoint' 2>&1 | tail -1" 2>/dev/null || true
  sleep 5
  ssh $SSHO $METAL "sudo pkill -9 -f qemu-system-x86 2>/dev/null; sleep 5"
}

echo "### FRESH-BOOT VU CURVE  spin=$SPIN VUs=[$VUS] reps=[$REPS] ramp=$RAMP dur=$DUR"
for VU in $VUS; do
  for REP in $REPS; do
    RTAG="c_vu${VU}_r${REP}"
    echo "===== $RTAG : fresh boot ====="
    kill_guest
    boot_guest "$SPIN"
    if ! pg_ready; then echo "$RTAG PG_NOT_READY"; continue; fi
    WH=$(ssh $SSHO $DRV "PGPASSWORD=postgres psql -h $PGH -U postgres -p 5432 -d tpcc -tAc 'select count(*) from warehouse' 2>/dev/null" 2>/dev/null); echo "  warehouse=$WH"
    quiesce
    RUNSECS=$(( (RAMP + DUR) * 60 )); SAMP=$(( RUNSECS / 3 ))
    ssh $SSHO $METAL "nohup sh -c 'mpstat 3 $SAMP > /work/cpu-$RTAG.txt 2>&1' >/dev/null 2>&1 & echo cpu"
    ssh $SSHO $DRV "RAMP=$RAMP DUR=$DUR bash /tmp/hdb.sh run $PGH $VU $RTAG >/tmp/hdb-$RTAG.log 2>&1; echo RUN_RC=\$?"
    ssh $SSHO $DRV "grep -E 'TEST RESULT|VUCOMPLETE_AFTER' /tmp/hdb-$RTAG.log 2>/dev/null | tail -2" | tee "$LOCAL/$RTAG.result.txt"
    scp $SSHO "$DRV:/tmp/hdb-$RTAG.log" "$LOCAL/" 2>/dev/null
    ssh $SSHO $METAL "awk '/all/{u=100-\$NF; s+=u; n++; usr+=\$3; sys+=\$5} END{if(n)printf \"metal_cpu_busy_mean=%.1f%% usr=%.1f sys=%.1f samples=%d\n\", s/n, usr/n, sys/n, n}' /work/cpu-$RTAG.txt 2>/dev/null" | tee -a "$LOCAL/$RTAG.result.txt"
  done
done
kill_guest
echo "CURVE_DONE"
