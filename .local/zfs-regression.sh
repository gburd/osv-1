#!/usr/bin/env bash
# ZFS regression suite: run each test against the plain virtio ZFS image and
# classify PASS/FAIL/CRASH.  No Crucible flags -- these exercise the ZFS layer
# and OSv subsystems, not the distributed block driver.  Confirms the Crucible
# async-sender + block-dispatcher commits introduced no regressions.
set -uo pipefail

BUILD=/scratch/gburd/osv-build
OUT=/scratch/gburd/zfs-regression
mkdir -p "$OUT"
cd "$BUILD" || exit 1

TESTS="tst-zfs-direct-io tst-zfs-trim tst-zfs-encryption tst-shm-consistency tst-huge tst-io_uring"

pass=0
fail=0
for t in $TESTS; do
  log="$OUT/$t.log"
  echo "===== $t ====="
  timeout 300 nix-shell -p boost ncurses --run "
    ./scripts/run.py -k --arch=x86_64 --vnc none -m 1024 -c2 --novnc \
      -e 'tests/$t.so'
  " > "$log" 2>&1
  crash=$(grep -aoE "general protection fault|page fault|nonexistent segment|PANIC|VERIFY|Aborted|Assertion failed" "$log" | head -1)
  if [ -n "$crash" ]; then
    echo "  $t: CRASH [$crash]"
    fail=$((fail+1))
  elif grep -aqE "PASSED|SUCCESS|All tests passed|tests passed|OK \(|No errors|tests, 0 failures|completed successfully|PASS" "$log"; then
    echo "  $t: PASS"
    pass=$((pass+1))
  else
    echo "  $t: UNKNOWN (inspect $log)"
    fail=$((fail+1))
  fi
done
echo "--- PASS=$pass FAIL/UNKNOWN=$fail ---"
