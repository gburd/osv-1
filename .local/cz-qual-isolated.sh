#!/usr/bin/env bash
# Isolated Crucible qualification: restart 3 fresh downstairs before EVERY run
# so a teardown-time hash-validation flood in run N cannot poison run N+1 (the
# downstairs has no log rate-limit and will fill the disk if reused after a
# severed-frame desync).  Each run gets a pristine region.  We are qualifying
# the use-after-free fix (crucible_io_dispatcher): the pass criterion is ZERO
# crashes (no PANIC / GP fault / VERIFY / Aborted) and a completed 256 MiB
# sweep on every run.
set -uo pipefail

BUILD=/scratch/gburd/osv-build
DS=/scratch/crucible-test/crucible/target/release/crucible-downstairs
UUID=2321c7c3-8084-41f3-a6de-fa368d51e3b6
BASE=/scratch/gburd/cz-test
OUT=/scratch/gburd/cz-qual-iso
N=${1:-12}
mkdir -p "$OUT"

stop_downstairs() {
  # Stop promptly so a post-sweep hash-validation desync cannot keep flooding
  # the (unrotated) downstairs log and fill /scratch.
  pkill -f "crucible-downstairs run --address 0.0.0.0 --port 381" 2>/dev/null || true
  sleep 1
}

restart_downstairs() {
  stop_downstairs
  local TS; TS=$(date +%s%N)
  for trip in r1:3811 r2:3812 r3:3813; do
    local r=${trip%%:*} p=${trip##*:}
    local D="${BASE}/${r}"
    # Move the prior region aside (recoverable) rather than deleting it.
    [ -e "$D" ] && mv "$D" "${D}.old.${TS}"
    mkdir -p "$D"
    "$DS" create --data "$D" --uuid "$UUID" --block-size 4096 \
      --extent-size 16384 --extent-count 64 >/dev/null 2>&1
    nohup "$DS" run --address 0.0.0.0 --port "$p" --data "$D" \
      > "${BASE}/ds-${p}.run.log" 2>&1 &
  done
  sleep 2
}

pass=0; crash=0; hang=0
for run in $(seq 1 "$N"); do
  log="$OUT/run-$run.log"
  echo "===== RUN $run -> $log ====="
  restart_downstairs
  cd "$BUILD" || exit 1
  timeout 360 nix-shell -p boost ncurses --run "
    ./scripts/run.py -k --arch=x86_64 --vnc none -m 1024 -c2 --novnc \
      --crucible0=192.168.122.1:3811,192.168.122.1:3812,192.168.122.1:3813 \
      --crucible0-uuid=$UUID \
      --crucible-block-size=4096 \
      -e 'tests/tst-crucible-zfs.so'
  " > "$log" 2>&1
  stop_downstairs
  sig=$(grep -aoE "general protection fault|page fault|overlapping with existing|nonexistent segment|PANIC|VERIFY|Aborted|Assertion" "$log" | head -1)
  if [ -n "$sig" ]; then
    echo "  run $run: CRASH [$sig]"
    crash=$((crash+1))
  elif grep -aq "workload sweep across 6 sizes" "$log"; then
    echo "  run $run: CLEAN (full 256MiB sweep)"
    pass=$((pass+1))
  else
    echo "  run $run: HANG (last: $(grep -aE 'MiB' "$log" | tail -1))"
    hang=$((hang+1))
  fi
done
pkill -f "crucible-downstairs run --address 0.0.0.0 --port 381" 2>/dev/null || true
echo "===== SUMMARY: $pass clean / $crash crash / $hang hang (of $N) ====="
