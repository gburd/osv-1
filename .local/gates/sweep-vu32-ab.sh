#!/bin/bash
# VU32 fixed-vs-adaptive A/B (the low-mode-cured proof). fresh-boot-per-cell.
# fixed-10000 (ADAPT=0) x4 + adaptive (ADAPT=1) x2 more. Does fixed reproduce the 0.5-vCPU low-mode?
set -uo pipefail
GATES=/home/gburd/ws/osv/.local/gates
cd "$GATES"
SWEEP="$GATES/cells/SWEEP-vu32-ab.log"
: > "$SWEEP"
# label:adapt  -- fixed reps first (the low-mode reproducer), then extra adaptive
CELLS="f1:0 f2:0 f3:0 f4:0 a6:1 a7:1"
for c in $CELLS; do
  L="${c%%:*}"; AD="${c##*:}"
  if [ "$AD" = 0 ]; then TAG="osv-vu32-fixed10000-r${L#f}"; else TAG="osv-vu32-r${L#a}"; fi
  echo "$(date +%H:%M:%S) START $TAG (adapt=$AD)" >> "$SWEEP"
  bash "$GATES/runcell-osv.sh" 32 "${L#[fa]}" "$AD" >"$GATES/cells/$TAG.drive.log" 2>&1
  NOPM=$(grep -oE 'System achieved [0-9]+ NOPM' "$GATES/cells/$TAG.cell.txt" 2>/dev/null | grep -oE '[0-9]+' | head -1)
  DISC=$(grep -oE 'during_run_median_pct_of_one_core=[0-9]+|ALL_SAMPLES_LOW.*WAITING' "$GATES/cells/$TAG.instr.txt" 2>/dev/null | head -1)
  echo "$(date +%H:%M:%S) DONE  $TAG NOPM=${NOPM:-NONE} DISC=${DISC:-NONE}" >> "$SWEEP"
done
echo "$(date +%H:%M:%S) AB_COMPLETE" >> "$SWEEP"
