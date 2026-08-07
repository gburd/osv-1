#!/usr/bin/env bash
# Boot the libc-behavior tests as the musl 1.2.1 unit-test proxy (Waldek's bar).
# Assumes the kernel+tests image was just rebuilt on the current branch.
# Each test boots its own guest; collect pass/fail.
set -uo pipefail
cd /home/gburd/ws/osv || exit 2

TESTS=(
  tst-stdio.so
  tst-printf.so
  tst-string.so
  tst-time.so
  tst-mmap.so
  tst-pthread.so
  tst-pthread-clock.so
  tst-fs.so
  tst-strerror_r.so
)

OUT=/tmp/musl-unit
mkdir -p "$OUT"
for t in "${TESTS[@]}"; do
  if [ ! -f "build/release.x64/tests/$t" ]; then
    echo "SKIP  $t (not built)"
    continue
  fi
  timeout 120 ./scripts/run.py -k --arch=x86_64 --vnc none -m 512 -c1 \
    -e "tests/$t" >"$OUT/$t.txt" 2>&1
  rc=$?
  # boost.test "*** N failures" or "No errors detected"; ignore the guest exit code
  fail=$(grep -aoE '\*\*\* [0-9]+ failures' "$OUT/$t.txt" | grep -aoE '[0-9]+' | head -1)
  if grep -qaE 'No errors detected|Leak detected.*0|test cases.*passed' "$OUT/$t.txt" \
     && [ -z "$fail" ]; then
    echo "PASS  $t"
  elif [ -n "$fail" ]; then
    echo "FAIL  $t ($fail failures)"
  else
    echo "????  $t (rc=$rc; inspect $OUT/$t.txt)"
  fi
done
