#!/usr/bin/env bash
set -uo pipefail
BUILD=/scratch/gburd/osv-build
DS=/scratch/crucible-test/crucible/target/release/crucible-downstairs
UUID=2321c7c3-8084-41f3-a6de-fa368d51e3b6
BASE=/scratch/gburd/cz-test
LOADER=$BUILD/build/release.x64/loader.elf
OUT=/scratch/gburd/cz-gdb
mkdir -p "$OUT"

pkill -f 'crucible-downstairs run --address 0.0.0.0 --port 381' 2>/dev/null || true
sleep 1
TS=$(date +%s%N)
for trip in r1:3811 r2:3812 r3:3813; do
  r=${trip%%:*}; p=${trip##*:}; D="${BASE}/${r}"
  [ -e "$D" ] && mv "$D" "${D}.old.${TS}"
  mkdir -p "$D"
  "$DS" create --data "$D" --uuid "$UUID" --block-size 4096 --extent-size 16384 --extent-count 64 >/dev/null 2>&1
  nohup "$DS" run --address 0.0.0.0 --port "$p" --data "$D" > "${BASE}/ds-${p}.run.log" 2>&1 &
done
sleep 2

cd "$BUILD" || exit 1
RUNLOG=$OUT/run.log
: > "$RUNLOG"
nix-shell -p boost ncurses --run "
  ./scripts/run.py -k --arch=x86_64 --vnc none -m 1024 -c2 --novnc \
    --crucible0=192.168.122.1:3811,192.168.122.1:3812,192.168.122.1:3813 \
    --crucible0-uuid=$UUID --crucible-block-size=4096 \
    -e 'tests/tst-crucible-zfs.so'
" > "$RUNLOG" 2>&1 &
RUNPID=$!
echo "run.py pid $RUNPID, log $RUNLOG"

# Wait for 64 MiB line (256 MiB write now in flight) or sweep-complete/early death.
for i in $(seq 1 120); do
  if grep -aq 'workload sweep across 6 sizes' "$RUNLOG"; then echo 'CLEAN before hang'; kill $RUNPID 2>/dev/null; pkill -f 'crucible-downstairs run' 2>/dev/null; exit 2; fi
  if grep -aqE '^[[:space:]]+64 MiB' "$RUNLOG"; then echo '64 MiB done, 256 MiB in flight'; break; fi
  kill -0 $RUNPID 2>/dev/null || { echo 'run.py exited early'; cat "$RUNLOG"; exit 3; }
  sleep 1
done

# Clean 256MiB completes in ~20s; wait 70s. If no sweep line, it's hung.
for i in $(seq 1 70); do
  if grep -aq 'workload sweep across 6 sizes' "$RUNLOG"; then echo 'CLEAN (256MiB finished)'; kill $RUNPID 2>/dev/null; pkill -f 'crucible-downstairs run' 2>/dev/null; exit 2; fi
  sleep 1
done
echo '=== HUNG: attaching gdb ==='

gdb -batch -nx \
  -iex 'set auto-load safe-path /' \
  -iex 'set pagination off' \
  -iex 'set print pretty on' \
  -ex 'connect localhost:1234' \
  -ex 'osv info threads' \
  -ex 'osv thread apply all bt' \
  "$LOADER" > "$OUT/gdb-threads.txt" 2>&1
echo "gdb dump -> $OUT/gdb-threads.txt ($(wc -l < $OUT/gdb-threads.txt) lines)"

kill $RUNPID 2>/dev/null
pkill -f 'crucible-downstairs run --address 0.0.0.0 --port 381' 2>/dev/null || true
