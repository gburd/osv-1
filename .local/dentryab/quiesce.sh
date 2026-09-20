#!/bin/bash
# HARDENED quiesce: CHECKPOINT until TWO CONSECUTIVE sub-1s checkpoints (per the zilab
# false-quiesce lesson: one fast checkpoint right after crash-recovery drained a backlog
# and inflated a result 2.4x). Records every checkpoint duration.
# ARGS: <guest-ip> <tag>   ; runs on DRIVER (psql). Writes /tmp/quiesce-<tag>.log
set -uo pipefail
H="$1"; TAG="$2"
LOG=/tmp/quiesce-$TAG.log
: > "$LOG"
consec=0
for i in $(seq 1 25); do
  T=$( { /usr/bin/time -f '%e' psql -h "$H" -p 5432 -U postgres -d postgres -tAc 'CHECKPOINT' \
        -v ON_ERROR_STOP=1 ; } 2>&1 | tail -1 )
  # /usr/bin/time prints the elapsed seconds on stderr as the last line
  echo "checkpoint $i: ${T}s" | tee -a "$LOG"
  # numeric compare: sub-1s?
  if awk "BEGIN{exit !($T < 1.0)}" 2>/dev/null; then
    consec=$((consec+1))
  else
    consec=0
  fi
  if [ "$consec" -ge 2 ]; then
    echo "QUIESCED after $i checkpoints (2 consecutive sub-1s)" | tee -a "$LOG"
    exit 0
  fi
  sleep 2
done
echo "QUIESCE_INCOMPLETE after 25 checkpoints (never got 2 consecutive sub-1s)" | tee -a "$LOG"
exit 1
