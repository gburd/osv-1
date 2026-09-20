#!/bin/bash
# Local driver: sweep syncwrite points on the box via detached nohup + poll.
# Native qemu (-M pc), no docker. Each point -> /tmp/z-<tag>.log on the box.
set -uo pipefail
source /home/gburd/ws/osv/.local/zilwake/box.env
source /home/gburd/ws/osv/.local/zilwake/ip.env
SSHO="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o LogLevel=ERROR"
OUTDIR=/home/gburd/ws/osv/.local/zilwake/raw
mkdir -p "$OUTDIR"

run_point() {  # tag threads secs reps extra_env
  local tag="$1" T="$2" SECS="$3" REPS="$4" EXTRA="${5:-}"
  local clog="/tmp/z-$tag.log"
  timeout 20 ssh $SSHO admin@$IP "nohup bash run-point.sh $clog pc $T $SECS $REPS \"$EXTRA\" >/tmp/nohup-$tag.log 2>&1 & echo started" >/dev/null 2>&1
  local budget=$(( SECS*REPS + 180 )) waited=0
  while [ $waited -lt $budget ]; do
    sleep 10; waited=$((waited+10))
    if timeout 15 ssh $SSHO admin@$IP "grep -qa ZFSBENCH_DONE $clog" 2>/dev/null; then break; fi
  done
  timeout 20 ssh $SSHO admin@$IP "cat $clog" > "$OUTDIR/$tag.txt" 2>/dev/null
  echo "=== $tag (t=$T secs=$SECS reps=$REPS env='${EXTRA:-none}') waited=${waited}s ==="
  grep -aE "RESULT (syncwrite|ZILWAKE)|mode=per-queue|OSV_ZIL_WAKE|ZFSBENCH_DONE" "$OUTDIR/$tag.txt" \
    || echo "  <no result - see $tag.txt>"
  echo
}

"$@"
