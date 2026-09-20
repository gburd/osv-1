#!/bin/bash
# LINUX VU64 wedge/scale diagnostic: run HammerDB VU64 against the already-up Linux PG, sample
# WALWrite pileup + active + xact_commit delta + NVMe + qemu-cpu every 15s for ~6min. Determines
# whether Linux (same ZFS/io_uring/HW) ALSO wedges on WALWrite at VU64 (=PG/ZFS ceiling) or scales.
# ARG: <vu> <label>
set -uo pipefail
. /home/gburd/ws/osv/.local/gates/env.sh
VU="${1:-64}"; LABEL="${2:-linux-vu64}"
PGH=$METALPRIV
OUT=/home/gburd/ws/osv/.local/gates/cells/wedge-$LABEL.txt
: > "$OUT"
echo "=== LINUX WEDGE/SCALE label=$LABEL vu=$VU (same ZFS/io_uring/HW as OSv) ===" | tee -a "$OUT"
IOEFF=$(timeout 15 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=8 psql -h $PGH -U postgres -d tpcc -tAc 'show io_method' 2>&1" 2>&1)
echo "io_method_in_effect=$IOEFF" | tee -a "$OUT"
timeout 120 ssh $SSHO $DRV "bash /tmp/quiesce.sh $PGH 2>&1 | tail -2" 2>&1 | tee -a "$OUT"
timeout 20 ssh $SSHO $DRV "cd /tmp && setsid --fork bash /tmp/hdb.sh run $PGH $VU $LABEL </dev/null >/tmp/hdbdrive-$LABEL.out 2>&1; echo HDB_DETACHED" 2>&1 | tee -a "$OUT"
echo "--- SAMPLES (t, WALWrite_waiters, active, xact_commit_delta/15s, nvme_util%, qemu_pct_of_one_core) ---" | tee -a "$OUT"
prevx=""
for s in $(seq 1 24); do
  X=$(timeout 12 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=6 psql -h $PGH -U postgres -d tpcc -tAc \"select (select count(*) from pg_stat_activity where wait_event='WALWrite'), (select count(*) from pg_stat_activity where state='active'), (select xact_commit from pg_stat_database where datname='tpcc')\" 2>&1 | tr -d ' '" 2>&1)
  ww=$(echo "$X" | cut -d'|' -f1); ac=$(echo "$X" | cut -d'|' -f2); xc=$(echo "$X" | cut -d'|' -f3)
  dx="?"; [ -n "$prevx" ] && [ -n "$xc" ] && dx=$((xc - prevx)) 2>/dev/null; prevx="$xc"
  MET=$(timeout 15 ssh $SSHO $METAL "P=\$(pgrep -f 'smp 32'|head -1); a=\$(awk '{print \$14+\$15}' /proc/\$P/stat); u=\$(iostat -x 1 2 /dev/nvme1n1 2>/dev/null|grep nvme1n1|tail -1|awk '{print \$NF}'); sleep 4; b=\$(awk '{print \$14+\$15}' /proc/\$P/stat); echo \"\$u \$(( (b-a)*100/500 ))\"" 2>&1)
  echo "t=$((s*15))s WALWrite=$ww active=$ac xact_commit_delta=$dx nvme=$MET" | tee -a "$OUT"
  sleep 11
done
echo "--- final TEST RESULT ---" | tee -a "$OUT"
timeout 20 ssh $SSHO $DRV "grep -E 'TEST RESULT|System achieved' /tmp/hdb-$LABEL.log 2>/dev/null | tail -1" 2>&1 | tee -a "$OUT"
echo "=== LINUX WEDGE/SCALE $LABEL DONE ===" | tee -a "$OUT"
