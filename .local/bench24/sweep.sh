#!/bin/bash
# bench24 sweep driver: RO + RW at VU32/64/128/192, both arms, FRESH BOOT PER CELL,
# >=3 settled reps per cell.  Writes one line per rep to raw/ so RESULT.md can be
# rebuilt from the raw record, and appends incrementally so a crash mid-sweep
# still leaves every completed cell on disk.
#
# HARNESS NOTES (each one has cost a prior run):
#  * ANCHOR every pkill/pgrep pattern.  `pkill -f "pgbench"` once matched its own
#    sudo wrapper; here the pattern is anchored with ^ on the full path.
#  * The dataset is re-seeded PER CELL on both arms (stop/start discards the
#    instance store, so the pool is recreated empty every boot).
#  * Never void a rep without evidence.  Every rep is written down.
set -u
. /home/gburd/ws/osv/.local/bench24/env.sh
RAW="$NB/raw"; mkdir -p "$RAW"
SECS="${SECS:-60}"; REPS="${REPS:-3}"; SCALE="${SCALE:-100}"
PGB=/usr/lib/postgresql/18/bin

seed() {  # seed the dataset on <host>; both arms identical
  local H=$1
  ssh $SSHO $DRV "$PGB/pgbench -i -s $SCALE -h $H -U postgres -d postgres 2>&1 | tail -2"
}

hostof() { [ "$1" = osv ] && echo "$OSVPRIV" || echo "$LINUXPRIV"; }

cell() {  # <arm> <mode> <vu>
  local ARM=$1 MODE=$2 VU=$3
  local TAG="$ARM-$MODE-vu$VU"
  echo "=========== CELL $TAG  $(date -u +%H:%M:%S)Z ==========="
  bash "$NB/freshboot.sh" "$ARM" || { echo "CELL_ABORT $TAG boot"; return 1; }
  . "$NB/env.boxes"                 # re-read: freshboot may have rewritten IPs
  local H; H=$(hostof "$ARM")
  seed "$H"
  # console marker so the per-cell console slice is attributable
  echo "MARK $TAG seeded $(date -u +%H:%M:%S)Z"
  ssh $SSHO $DRV "bash /tmp/cell.sh $ARM $H $VU $MODE $SECS $REPS" 2>&1 | tee -a "$RAW/$TAG.txt"
  # per-cell instrumentation snapshot, per arm
  if [ "$ARM" = osv ]; then
    aws ec2 get-console-output --region $REGION --instance-id $OSVID --latest --output text 2>/dev/null \
      | grep -E "ARCPROBE|NONROTPROBE|SCHEDPROBE ncpu" | tail -25 > "$RAW/$TAG.console.txt"
  else
    ssh $SSHO $LINUX "grep -E '^(c|size|c_max)\b' /proc/spl/kstat/zfs/arcstats | awk '{print \$1\"=\"\$3}'; \
      echo ---; awk '/^cpu /{print}' /proc/stat" 2>/dev/null > "$RAW/$TAG.console.txt"
  fi
  echo "CELL_RECORDED $TAG"
}

scp $SSHO "$NB/cell.sh" $DRV:/tmp/ >/dev/null 2>&1

for MODE in ro rw; do
  for VU in 32 64 128 192; do
    [ "$MODE" = rw ] && [ "$VU" = 192 ] && continue   # RW sweep is VU32/64/128 per the prior curve
    for ARM in osv lin; do
      cell "$ARM" "$MODE" "$VU"
    done
  done
done
echo SWEEP_DONE
