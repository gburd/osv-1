#!/usr/bin/env bash
# Crucible qualification on the rewritten tip (sweep tree).
# 3 loopback downstairs on meh (ports 3811-3813 via slirp gw 192.168.122.1).
# Runs tst-crucible-blk (block-device sanity) then tst-crucible-zfs (ZFS-on-Crucible).
set -uo pipefail
BUILD=/scratch/gburd/sweep/osv
DS=/scratch/crucible-test/crucible/target/release/crucible-downstairs
UUID=2321c7c3-8084-41f3-a6de-fa368d51e3b6
BASE=/scratch/gburd/cz-test
OUT=/scratch/gburd/cz-qual-rewritten
mkdir -p "$OUT"
: >"$OUT/SUMMARY.txt"

stop_ds() {
  pkill -f "crucible-downstairs run --address 0.0.0.0 --port 381" 2>/dev/null || true
  sleep 1
}

start_ds() {
  stop_ds
  local TS
  TS=$(date +%s%N)
  for trip in r1:3811 r2:3812 r3:3813; do
    local r=${trip%%:*} p=${trip##*:}
    local D="${BASE}/${r}"
    [ -e "$D" ] && mv "$D" "${D}.old.${TS}"
    mkdir -p "$D"
    "$DS" create --data "$D" --uuid "$UUID" --block-size 4096 \
      --extent-size 16384 --extent-count 64 >/dev/null 2>&1
    nohup "$DS" run --address 0.0.0.0 --port "$p" --data "$D" \
      >"${BASE}/ds-${p}.run.log" 2>&1 &
  done
  sleep 2
}

run_test() {
  local name=$1 mem=$2
  local log="$OUT/$name.log"
  start_ds
  cd "$BUILD" || exit 1
  timeout 360 nix-shell -p boost ncurses --run "
    ./scripts/run.py -k --arch=x86_64 --vnc none -m $mem -c2 --novnc \
      --crucible0=192.168.122.1:3811,192.168.122.1:3812,192.168.122.1:3813 \
      --crucible0-uuid=$UUID --crucible-block-size=4096 \
      -e 'tests/$name.so'
  " >"$log" 2>&1
  local rc=$?
  stop_ds
  local crash
  crash=$(grep -aoE 'general protection fault|page fault|nonexistent segment|PANIC|VERIFY|Aborted|Assertion failed' "$log" | head -1)
  local verdict
  if [ -n "$crash" ]; then
    verdict="CRASH [$crash]"
  elif grep -aqiE 'passed|SUCCESS|sweep across' "$log" && ! grep -aqiE '\bFAIL' "$log"; then
    verdict=PASS
  else
    verdict="CHECK rc=$rc"
  fi
  printf '%-24s %-18s %s\n' "$name" "$verdict" "(see $log)" | tee -a "$OUT/SUMMARY.txt"
}

run_test tst-crucible-blk 512
run_test tst-crucible-zfs 1024
echo "===CZ_QUAL_DONE===" | tee -a "$OUT/SUMMARY.txt"
