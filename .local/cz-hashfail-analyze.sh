#!/usr/bin/env bash
# Analyze the Crucible downstairs logs from the last qual run for the
# "Failed write hash validation" flood: which replica(s), when it started
# relative to connection, and whether it is single-replica.
set -uo pipefail
BASE=/scratch/gburd/cz-test
for p in 3811 3812 3813; do
  g="${BASE}/ds-${p}.run.log"
  [ -f "$g" ] || continue
  sz=$(du -h "$g" | cut -f1)
  nf=$(grep -ac "Failed write hash validation" "$g")
  echo "=== ds-${p} (size ${sz}): ${nf} hash-fails ==="
  echo "  first connect:  $(grep -am1 'UpstairsConnection' "$g" | grep -oE '"time":"[^"]{19,30}')"
  echo "  first hashfail: $(grep -am1 'Failed write hash validation' "$g" | grep -oE '"time":"[^"]{19,30}')"
  echo "  disconnects:    $(grep -ac 'disconnect' "$g")"
  echo "  msg types (non-hashfail, first 100k lines):"
  head -100000 "$g" | grep -aoE '"msg":"[^"]{0,40}' | grep -av 'hash validation' \
    | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
done
