#!/usr/bin/env bash
# Rebind the 3 Crucible downstairs to 0.0.0.0 (so the libvirt guest can reach
# them at 192.168.122.1) with fresh regions for a clean qualification baseline.
set -uo pipefail

DS=/scratch/crucible-test/crucible/target/release/crucible-downstairs
UUID=2321c7c3-8084-41f3-a6de-fa368d51e3b6
BASE=/scratch/gburd/cz-test
TS=$(date +%s)

pkill -f "crucible-downstairs run -d ${BASE}" 2>/dev/null || true
pkill -f "crucible-downstairs run --address 0.0.0.0 --port 381" 2>/dev/null || true
sleep 1

for trip in r1:3811 r2:3812 r3:3813; do
  r=${trip%%:*}
  p=${trip##*:}
  D="${BASE}/${r}"
  if [ -e "$D" ]; then
    mv "$D" "${D}.old.${TS}"
  fi
  mkdir -p "$D"
  "$DS" create --data "$D" --uuid "$UUID" --block-size 4096 \
    --extent-size 16384 --extent-count 64 >/dev/null 2>&1
  nohup "$DS" run --address 0.0.0.0 --port "$p" --data "$D" \
    > "${BASE}/ds-${p}.fresh.log" 2>&1 &
  echo "started ${r} on 0.0.0.0:${p} (pid $!)"
done

sleep 2
echo "===VERIFY==="
for p in 3811 3812 3813; do
  if timeout 2 bash -c "echo > /dev/tcp/192.168.122.1/${p}" 2>/dev/null; then
    echo "port ${p} OPEN"
  else
    echo "port ${p} closed"
  fi
done
