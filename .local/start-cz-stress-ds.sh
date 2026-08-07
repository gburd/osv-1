#!/usr/bin/env bash
set -uo pipefail
DS=/scratch/crucible-test/crucible/target/release/crucible-downstairs
UUID=2321c7c3-8084-41f3-a6de-fa368d51e3b6
BASE=/scratch/gburd/cz-stress
pkill -f "crucible-downstairs run" 2>/dev/null || true
sleep 1
TS=$(date +%s)
for trip in r1:3811 r2:3812 r3:3813; do
  r=${trip%%:*}
  p=${trip##*:}
  D=$BASE/$r
  [ -e "$D" ] && mv "$D" "$D.old.$TS"
  mkdir -p "$D"
  "$DS" create --data "$D" --uuid "$UUID" --block-size 4096 \
    --extent-size 16384 --extent-count 64 >/dev/null 2>&1
  nohup "$DS" run --address 0.0.0.0 --port "$p" --data "$D" \
    > "$BASE/ds-$p.log" 2>&1 &
done
sleep 2
echo "=== running downstairs ==="
pgrep -af "crucible-downstairs run" | grep -oE "port 381[0-9]" | sort
