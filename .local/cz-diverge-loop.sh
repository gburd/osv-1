#!/usr/bin/env bash
set -uo pipefail
cd /scratch/gburd/osv-build
OUTDIR=/scratch/gburd/cz-diverge
mkdir -p "$OUTDIR"
N=${1:-12}
for i in $(seq 1 "$N"); do
  log="$OUTDIR/run-$i.log"
  echo "===== RUN $i -> $log ====="
  timeout 230 nix-shell -p boost ncurses --run \
    "./scripts/run.py -k --arch=x86_64 --vnc none -m 1024 -c2 --novnc \
       --crucible0=192.168.122.1:3811,192.168.122.1:3812,192.168.122.1:3813 \
       --crucible0-uuid=2321c7c3-8084-41f3-a6de-fa368d51e3b6 \
       --crucible-block-size=4096 \
       -e 'tests/tst-crucible-zfs.so'" >"$log" 2>&1
  div=$(grep -ac "READ DIVERGENCE" "$log")
  if [ "$div" -gt 0 ]; then
    echo "  run $i: *** $div DIVERGENCE lines ***"
    grep -a "READ DIVERGENCE" "$log" | head -3
  fi
  sig=$(grep -aoE "general protection fault|page fault|overlapping with existing|nonexistent segment|PANIC|VERIFY|Aborted" "$log" | head -1)
  if [ -n "$sig" ]; then
    echo "  run $i: CRASH [$sig]"
  elif grep -aq "256 MiB" "$log" && grep -aq "workload sweep across 6 sizes" "$log"; then
    echo "  run $i: clean (full sweep)"
  else
    last=$(grep -aE "MiB" "$log" | tail -1)
    echo "  run $i: HANG (last: $last)"
  fi
done
echo "===== LOOP DONE ====="
