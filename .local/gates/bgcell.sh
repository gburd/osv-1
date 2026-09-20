#!/bin/bash
# Run a sequence of OSv cells in the background with polling (each runcell blocks ~15-18min).
# Usage: bgcell.sh osv <vu> <rep> [adapt]   OR   bgcell.sh linux <vu> <rep>
# Launches the appropriate runcell detached, writes a .done marker, so the caller can poll.
set -uo pipefail
GATES=/home/gburd/ws/osv/.local/gates
ARM="$1"; VU="$2"; REP="$3"; ADAPT="${4:-1}"
if [ "$ARM" = osv ]; then
  TAG="osv-vu$VU-r$REP"; [ "$ADAPT" = 0 ] && TAG="osv-vu$VU-fixed10000-r$REP"
  nohup bash "$GATES/runcell-osv.sh" "$VU" "$REP" "$ADAPT" >"$GATES/cells/$TAG.drive.log" 2>&1
else
  TAG="linux-vu$VU-r$REP"
  nohup bash "$GATES/runcell-linux.sh" "$VU" "$REP" >"$GATES/cells/$TAG.drive.log" 2>&1
fi
echo "CELL_DONE $TAG" >> "$GATES/cells/$TAG.drive.log"
