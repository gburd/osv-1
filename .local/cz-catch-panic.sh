#!/usr/bin/env bash
# Run tst-crucible-zfs repeatedly, capturing FULL serial output each run, until
# the btree VERIFY3P panic (or any SPL PANIC / fault / Aborted) reproduces.
# Saves each run's full log; on a panic, prints the whole tail with backtrace.
set -uo pipefail
cd /scratch/gburd/osv-build
UUID=2321c7c3-8084-41f3-a6de-fa368d51e3b6
OUT=/scratch/gburd/cz-panic-capture
mkdir -p "$OUT"

for run in $(seq 1 8); do
  log="$OUT/run-$run.log"
  echo "===== RUN $run -> $log ====="
  timeout 200 nix-shell -p boost ncurses --run "
    ./scripts/run.py -k --arch=x86_64 --vnc none -m 1024 -c2 --novnc \
      --crucible0=192.168.122.1:3811,192.168.122.1:3812,192.168.122.1:3813 \
      --crucible0-uuid=$UUID \
      --crucible-block-size=4096 \
      -e 'tests/tst-crucible-zfs.so'
  " > "$log" 2>&1
  rc=$?
  if grep -qE 'PANIC|page fault|Aborted|VERIFY|GP fault|Assertion' "$log"; then
    echo "===== PANIC REPRODUCED on run $run (rc=$rc) ====="
    echo "----- last 60 lines of $log -----"
    tail -60 "$log"
    echo "===== END (panic on run $run) ====="
    exit 0
  fi
  echo "  run $run clean-ish (rc=$rc); last line:"
  tail -1 "$log"
done
echo "===== NO PANIC in 8 runs ====="
