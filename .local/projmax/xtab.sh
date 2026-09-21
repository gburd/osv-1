#!/bin/bash
# Cross-tab the reverse-apply presence test with a FORWARD-apply test, both in a
# worktree checked out AT the base. This is the discriminator the reverse test
# alone cannot give:
#
#   REV=all  FWD=no   -> PRESENT      (base has it; patch is redundant)
#   REV=none FWD=yes  -> ABSENT-CLEAN (base lacks it; applies cleanly => ADD)
#   REV=none FWD=no   -> DIVERGED     (base has a DIFFERENT version of the same
#                                      region, or a true conflict; needs judgement.
#                                      A reverse-only test calls this ABSENT, which
#                                      is a FALSE ABSENT.)
#   REV=some          -> PARTIAL      (mixed; per-PR judgement)
#
# Copyright (C) 2026 Greg Burd
set -u
WT=$1; OUT=$2
cd /home/gburd/ws/osv || exit 1
: > "$OUT"
while read -r n oid rest; do
  [ -z "${n:-}" ] && continue
  D=/tmp/pmdiff-$n.patch
  [ -s "$D" ] || git diff "upstream/master...$oid" > "$D"
  if git -C "$WT" apply --check "$D" 2>/dev/null; then FWD=CLEAN; else FWD=FAIL; fi
  if git -C "$WT" apply -R --check "$D" 2>/dev/null; then REV=ALL; else
    ok=$(awk '/^HUNKS_REVERSE/{print $2}' ".local/projmax/presence.txt.hunk-$n" 2>/dev/null | tail -1)
    tot=$(awk '/^HUNKS_TOTAL/{print $2}' ".local/projmax/presence.txt.hunk-$n" 2>/dev/null | tail -1)
    if [ "${ok:-0}" = 0 ]; then REV=NONE; else REV=SOME:${ok}/${tot}; fi
  fi
  # 3-way forward: does it apply with merge resolution?
  if git -C "$WT" apply --3way --check "$D" 2>/dev/null; then T3=OK; else T3=CONFLICT; fi
  echo "$n FWD=$FWD REV=$REV 3WAY=$T3" >> "$OUT"
done < /home/gburd/ws/osv/.local/projmax/prlist.txt
echo XTAB_DONE
