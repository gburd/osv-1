#!/bin/bash
# THE ONLY VALID PRESENCE TEST: reverse-apply each PR's diff-vs-upstream/master
# inside a worktree checked out AT the candidate base. Keyword greps and applies
# against the main working tree have both given wrong answers on this campaign.
#
# Copyright (C) 2026 Greg Burd
#
# Reverse-apply semantics:
#   git apply -R --check  succeeds  => every hunk of the PR is ALREADY in the base
#                                      => FULLY PRESENT
#   git apply -R --check  fails, but some hunks reverse => PARTIAL
#   no hunk reverses                                    => FULLY ABSENT
# ARGS: <base-worktree> <outfile>
set -u
WT=$1; OUT=$2
cd /home/gburd/ws/osv || exit 1
MB=upstream/master
: > "$OUT"
while read -r n oid mergeable draft ref title; do
  D=/tmp/pmdiff-$n.patch
  git diff "$MB...$oid" > "$D" 2>/dev/null
  NH=$(grep -c '^@@' "$D")
  if [ "$NH" = 0 ]; then echo "$n EMPTY 0 0" >> "$OUT"; continue; fi
  if git -C "$WT" apply -R --check "$D" 2>/dev/null; then
    echo "$n PRESENT $NH $NH" >> "$OUT"; continue
  fi
  # count how many hunks reverse-apply individually
  APPLIED=$(git -C "$WT" apply -R --check --recount --unidiff-zero "$D" 2>&1 >/dev/null | grep -c 'error:')
  # split into per-file diffs and test each; then per-hunk via --exclude is not
  # available, so use apply -R with 3way stats: count hunks that DO reverse by
  # applying to a scratch copy with --reverse and reading the reject report.
  R=$(git -C "$WT" apply -R --numstat "$D" 2>/dev/null | wc -l)
  OK=0
  # per-hunk test using splitpatch
  python3 /home/gburd/ws/osv/.local/projmax/hunkcheck.py "$WT" "$D" >> "$OUT.hunk-$n" 2>&1
  OK=$(awk '/^HUNKS_REVERSE/{print $2}' "$OUT.hunk-$n" | tail -1)
  TOT=$(awk '/^HUNKS_TOTAL/{print $2}' "$OUT.hunk-$n" | tail -1)
  OK=${OK:-0}; TOT=${TOT:-$NH}
  if [ "$OK" = "$TOT" ] && [ "$TOT" != 0 ]; then S=PRESENT
  elif [ "$OK" = 0 ]; then S=ABSENT
  else S=PARTIAL; fi
  echo "$n $S $OK $TOT" >> "$OUT"
done < /home/gburd/ws/osv/.local/projmax/prlist.txt
echo PROBE_DONE
