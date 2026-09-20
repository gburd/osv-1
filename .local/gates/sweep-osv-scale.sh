#!/bin/bash
# OSv adaptive VU64/128/192 sweep (re-run after the recovery-cascade contamination).
# fresh-boot-per-cell, ADAPT=1. Sequential. Logs per-cell NOPM+disc to cells/SWEEP-osv-scale.log.
set -uo pipefail
GATES=/home/gburd/ws/osv/.local/gates
cd "$GATES"
SWEEP="$GATES/cells/SWEEP-osv-scale.log"
: > "$SWEEP"
CELLS="64:1 64:2 64:3 128:1 128:2 128:3 192:1 192:2 192:3"
for c in $CELLS; do
  VU="${c%%:*}"; REP="${c##*:}"; TAG="osv-vu$VU-r$REP"
  echo "$(date +%H:%M:%S) START $TAG" >> "$SWEEP"
  bash "$GATES/runcell-osv.sh" "$VU" "$REP" 1 >"$GATES/cells/$TAG.drive.log" 2>&1
  NOPM=$(grep -oE 'System achieved [0-9]+ NOPM' "$GATES/cells/$TAG.cell.txt" 2>/dev/null | grep -oE '[0-9]+' | head -1)
  DISC=$(grep -oE 'during_run_median_pct_of_one_core=[0-9]+|ALL_SAMPLES_LOW.*WAITING' "$GATES/cells/$TAG.instr.txt" 2>/dev/null | head -1)
  echo "$(date +%H:%M:%S) DONE  $TAG NOPM=${NOPM:-NONE} DISC=${DISC:-NONE}" >> "$SWEEP"
done
echo "$(date +%H:%M:%S) SWEEP_SCALE_COMPLETE" >> "$SWEEP"
