#!/bin/bash
# Local driver: run the syncwrite sweep on the box via detached docker exec +
# poll (the ONLY reliable pattern - foreground ssh|pipe intermittently hangs).
# Each point writes /tmp/p-<tag>.log in the container; we poll for ZFSBENCH_DONE.
set -uo pipefail
IP=3.12.162.104
K=/home/gburd/.ssh/osv-lava
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o LogLevel=ERROR"
OUTDIR=/home/gburd/ws/osv/.local/walwake/raw
mkdir -p "$OUTDIR"

run_point() {  # tag threads secs reps extra_env extra_wl_kv
  local tag="$1" T="$2" SECS="$3" REPS="$4" EXTRA="${5:-}" WLEXTRA="${6:-}"
  local clog="/tmp/p-$tag.log"
  timeout 25 ssh $SSHO ec2-user@$IP "sudo docker exec -d bld bash /work/run-point.sh $clog $T $SECS $REPS \"$EXTRA\" \"$WLEXTRA\"" >/dev/null 2>&1
  # poll up to (secs*reps + 90)s
  local budget=$(( SECS*REPS + 120 )) waited=0
  while [ $waited -lt $budget ]; do
    sleep 10; waited=$((waited+10))
    if timeout 20 ssh $SSHO ec2-user@$IP "sudo docker exec bld grep -qa ZFSBENCH_DONE $clog" 2>/dev/null; then break; fi
  done
  # pull the log local
  timeout 25 ssh $SSHO ec2-user@$IP "sudo docker exec bld cat $clog" > "$OUTDIR/$tag.txt" 2>/dev/null
  echo "=== $tag (t=$T secs=$SECS reps=$REPS ${EXTRA:-nofix}) waited=${waited}s ==="
  grep -aE "RESULT (syncwrite|OSV_)|ZFSBENCH_DONE" "$OUTDIR/$tag.txt" || echo "  <no result - see $tag.txt>"
}

"$@"
