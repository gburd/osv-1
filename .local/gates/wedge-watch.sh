#!/bin/bash
# VU64 wedge diagnostic: boot OSv (given ADAPT + IOMETHOD), run HammerDB VU64 detached, then SAMPLE
# every 15s for ~5min: WALWrite pileup, active backends, committed-xact delta (progress?), NVMe IO,
# qemu-cpu. Determines DEADLOCK (never drains) vs SLOW-STALL (eventually resumes) and localizes the
# path (io_uring vs worker). Writes cells/wedge-<label>.txt.
# ARGS: <label> <adapt 1|0> <iomethod io_uring|worker>
set -uo pipefail
. /home/gburd/ws/osv/.local/gates/env.sh
LABEL="$1"; ADAPT="${2:-1}"; IOM="${3:-io_uring}"
PGH=$METALPRIV
OUT=/home/gburd/ws/osv/.local/gates/cells/wedge-$LABEL.txt
: > "$OUT"
echo "=== WEDGE-WATCH label=$LABEL ADAPT=$ADAPT io_method=$IOM ===" | tee -a "$OUT"

# kill prior guest (detached), wait lock free
timeout 20 ssh $SSHO $METAL "sudo setsid --fork sh -c 'pkill -9 -f \"qemu-system-x86_64 -M pc\"' </dev/null >/dev/null 2>&1; echo K" 2>&1 >/dev/null || true
for k in $(seq 1 15); do sleep 3; R=$(timeout 18 ssh $SSHO $METAL "if sudo fuser /work/osv/build/last/usr.img >/dev/null 2>&1; then echo LOCKED; else echo FREE; fi" 2>&1); [ "$R" = FREE ] && break; done

# boot with chosen io_method (override the PGARGS io_method via a per-boot env the boot script reads)
timeout 20 ssh $SSHO $METAL "sudo ADAPT=$ADAPT FIXEDSPIN=10000 IOMETHOD=$IOM setsid --fork bash /tmp/boot-osv.sh run </dev/null >/dev/null 2>&1; echo BOOTED" 2>&1 | tee -a "$OUT"

# wait for PG (tolerate recovery up to ~18min)
up=0
for i in $(seq 1 180); do
  R=$(timeout 15 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=8 psql -h $PGH -U postgres -d tpcc -tAc 'select 1' 2>&1" 2>&1)
  echo "$R" | grep -q '^1$' && { echo "PG up ($i)" | tee -a "$OUT"; up=1; break; }
  sleep 6
done
[ "$up" = 1 ] || { echo "PG NEVER UP - abort" | tee -a "$OUT"; exit 2; }

# confirm io_method actually in effect
IOEFF=$(timeout 15 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=8 psql -h $PGH -U postgres -d tpcc -tAc 'show io_method' 2>&1" 2>&1)
echo "io_method_in_effect=$IOEFF" | tee -a "$OUT"

# quiesce
timeout 120 ssh $SSHO $DRV "bash /tmp/quiesce.sh $PGH 2>&1 | tail -2" 2>&1 | tee -a "$OUT"

# launch HammerDB VU64 detached
timeout 20 ssh $SSHO $DRV "cd /tmp && setsid --fork bash /tmp/hdb.sh run $PGH 64 $LABEL </dev/null >/tmp/hdbdrive-$LABEL.out 2>&1; echo HDB_DETACHED" 2>&1 | tee -a "$OUT"

# sample every 15s for ~6min (24 samples). Track committed-xact delta = real progress.
echo "--- SAMPLES (t, walwrite_waiters, active, xact_committed_delta_since_prev, nvme_util%, qemu_5s_pct_of_one_core) ---" | tee -a "$OUT"
prevx=""
for s in $(seq 1 24); do
  X=$(timeout 12 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=6 psql -h $PGH -U postgres -d tpcc -tAc \"select (select count(*) from pg_stat_activity where wait_event='WALWrite'), (select count(*) from pg_stat_activity where state='active'), (select xact_commit from pg_stat_database where datname='tpcc')\" 2>&1 | tr -d ' '" 2>&1)
  ww=$(echo "$X" | cut -d'|' -f1); ac=$(echo "$X" | cut -d'|' -f2); xc=$(echo "$X" | cut -d'|' -f3)
  dx="?"; [ -n "$prevx" ] && [ -n "$xc" ] && dx=$((xc - prevx)) 2>/dev/null; prevx="$xc"
  MET=$(timeout 15 ssh $SSHO $METAL "P=\$(pgrep -f 'smp 32'|head -1); a=\$(awk '{print \$14+\$15}' /proc/\$P/stat); u=\$(iostat -x 1 2 /dev/nvme1n1 2>/dev/null|grep nvme1n1|tail -1|awk '{print \$NF}'); sleep 4; b=\$(awk '{print \$14+\$15}' /proc/\$P/stat); echo \"\$u \$(( (b-a)*100/500 ))\"" 2>&1)
  echo "t=$((s*15))s WALWrite=$ww active=$ac xact_commit_delta=$dx nvme=$MET" | tee -a "$OUT"
  sleep 11
done
echo "=== WEDGE-WATCH $LABEL DONE ===" | tee -a "$OUT"
