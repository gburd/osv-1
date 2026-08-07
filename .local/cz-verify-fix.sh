#!/usr/bin/env bash
# Verify the read-dependency (read-your-writes) fix: run tst-crucible-zfs 12
# times, capturing FULL serial output. The bug we are confirming gone is the
# metaslab range-tree double-accounting panic (btree VERIFY3P / range-tree
# nonexistent-segment warnings). Report per-run outcome and whether the full
# write sweep completed.
set -uo pipefail
cd /scratch/gburd/osv-build
UUID=2321c7c3-8084-41f3-a6de-fa368d51e3b6
OUT=/scratch/gburd/cz-verify-fix
mkdir -p "$OUT"

panics=0
sweeps=0
for run in $(seq 1 12); do
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
  if grep -qE 'PANIC|page fault|Aborted|VERIFY|GP fault|Assertion|nonexistent segment|overlapping with existing' "$log"; then
    echo "  >>> CORRUPTION/PANIC on run $run (rc=$rc) <<<"
    panics=$((panics+1))
    grep -nE 'PANIC|Aborted|VERIFY|nonexistent segment|overlapping|page fault' "$log" | head -5
  else
    echo "  run $run clean (rc=$rc)"
  fi
  # Did the full 256MiB sweep complete?
  if grep -q '256 MiB' "$log"; then
    echo "  full sweep COMPLETED (saw 256 MiB step)"
    sweeps=$((sweeps+1))
  else
    echo "  last sweep line: $(grep -E 'MiB' "$log" | tail -1)"
  fi
done
echo "===== SUMMARY: $panics/12 runs had corruption/panic; $sweeps/12 completed full sweep ====="
