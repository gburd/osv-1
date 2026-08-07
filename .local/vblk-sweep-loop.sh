#!/usr/bin/env bash
set -uo pipefail
cd /scratch/gburd/osv-build
OUTDIR=/scratch/gburd/vblk-sweep
mkdir -p "$OUTDIR"
N=${1:-12}
for i in $(seq 1 "$N"); do
  log="$OUTDIR/run-$i.log"
  echo "===== RUN $i -> $log ====="
  timeout 300 nix-shell -p boost ncurses --run \
    "./scripts/run.py -k --arch=x86_64 --vnc none -m 1024 -c2 --novnc \
       --second-disk-image /scratch/gburd/vblk-scratch.raw \
       -e \"--env=CRUCIBLE_ZFS_DEV=/dev/vblk1 tests/tst-crucible-zfs.so\"" >"$log" 2>&1
  sig=$(grep -aoE "general protection fault|page fault|overlapping with existing|nonexistent segment|PANIC|VERIFY|Aborted" "$log" | head -1)
  if [ -n "$sig" ]; then
    echo "  run $i: CRASH [$sig]"
  elif grep -aq "workload sweep across 6 sizes" "$log"; then
    echo "  run $i: clean (full sweep)"
  else
    last=$(grep -aE "MiB" "$log" | tail -1)
    echo "  run $i: HANG (last: $last)"
  fi
done
echo "===== LOOP DONE ====="
