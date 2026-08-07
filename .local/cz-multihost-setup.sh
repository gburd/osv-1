#!/usr/bin/env bash
# Recreate one fresh Crucible region on this host and (re)start a single
# downstairs bound to 0.0.0.0:<port>. Precise: only kills a downstairs that
# was serving THIS data dir, so unrelated downstairs (e.g. meh's loopback
# single-host set) keep running.
# Args: <binary> <data-dir> <uuid> <port>
set -euo pipefail

BIN="$1"
DATA="$2"
UUID="$3"
PORT="$4"

# Kill only a downstairs already serving this exact data dir.
OLD=$(pgrep -f "crucible-downstairs run.*${DATA}" || true)
if [ -n "$OLD" ]; then
  kill $OLD 2>/dev/null || true
  sleep 1
fi

rm -rf "$DATA"
mkdir -p "$DATA"

"$BIN" create \
  --data "$DATA" \
  --uuid "$UUID" \
  --block-size 4096 \
  --extent-size 16384 \
  --extent-count 64

LOG="${DATA%/*}/ds-${PORT}.log"
nohup "$BIN" run --address 0.0.0.0 --port "$PORT" --data "$DATA" \
  > "$LOG" 2>&1 &
DSPID=$!

sleep 2
echo "started downstairs pid ${DSPID} on 0.0.0.0:${PORT} data=${DATA} uuid=${UUID}"
pgrep -af "crucible-downstairs run.*${DATA}" | head
