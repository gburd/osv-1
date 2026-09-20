#!/bin/bash
# Driver-side arm sweep: for each (VU,repeat) do quiesce -> cell2 -> stash xtprof.
# ARGS: <guest-ip> <arm-tag e.g. pc|gl> <space-separated "VU:reps" specs>
# Example: sweep.sh 172.31.12.3 pc "8:3 32:3 64:3"
# Writes /tmp/<arm>-vu<VU>-r<n>.* and a /tmp/sweep-<arm>.log summary. Runs under nohup.
set -uo pipefail
H="$1"; ARM="$2"; shift 2
SPECS="$*"
SUM=/tmp/sweep-$ARM.log
echo "SWEEP START arm=$ARM specs=$SPECS $(date -u)" | tee -a "$SUM"
for spec in $SPECS; do
  VU="${spec%%:*}"; REPS="${spec##*:}"
  for n in $(seq 1 "$REPS"); do
    TAG="$ARM-vu$VU-r$n"
    echo "=== CELL $TAG quiesce $(date -u) ===" | tee -a "$SUM"
    bash /tmp/quiesce.sh "$H" "$TAG" 2>&1 | tee -a "$SUM"
    echo "=== CELL $TAG run $(date -u) ===" | tee -a "$SUM"
    bash /tmp/cell2.sh "$H" "$VU" "$TAG" > /tmp/cell2-$TAG.out 2>&1
    cp -f /tmp/hdbxtprofile.log /tmp/xtprof-$TAG.log 2>/dev/null || true
    NOPM=$(grep -oE 'System achieved [0-9]+ NOPM' /tmp/cell-$TAG.log 2>/dev/null | grep -oE '[0-9]+' | head -1)
    VUC=$(grep -oE 'VUCOMPLETE_AFTER [0-9]+ s' /tmp/cell-$TAG.log 2>/dev/null | head -1)
    echo "RESULT $TAG NOPM=$NOPM $VUC $(date -u)" | tee -a "$SUM"
  done
done
echo "SWEEP DONE arm=$ARM $(date -u)" | tee -a "$SUM"
