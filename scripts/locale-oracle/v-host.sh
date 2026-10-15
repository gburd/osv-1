#!/bin/bash
# Copyright (C) 2026 Greg Burd.
#
# This work is open source software, licensed under the terms of the
# BSD license as described in the LICENSE file in the top-level directory.
#
# Stage 1a-2 on the host, against the current build: v.sh <tag> [what...]
#   tld      tst-locale-data through run.py (its SUMMARY line; test.py hides it)
#   dump     misc-locale-dump in dir and archive mode, 20 locales
#   ctype    misc-ctype-dump, 20 locales: sha256 of each against glibc's (cdump/g-*.sha)
# One QEMU at a time; each run under timeout; a leftover QEMU of this tree is killed by pid.
set -u
export PATH="/usr/sbin:/sbin:$PATH"
cd /srv/osv-v2/osv; C=/srv/osv-v2/console-s1a2; mkdir -p $C
say() { echo "[$(date -u +%H:%M:%SZ)] $*" >> $C/s1a2.console; }
guard() { local q=$(pgrep -cx qemu-system-x86)
          [ "$q" = 0 ] || { say "GUARD-FAIL qemu=$q before $1"; exit 1; }
          ! ss -ltn | grep -q ':1234 ' || { say "GUARD-FAIL :1234 busy before $1"; exit 1; }; }
reap() { for p in $(pgrep -x qemu-system-x86); do
           [ "$(stat -c %U /proc/$p)" = "$(id -un)" ] && tr '\0' ' ' < /proc/$p/cmdline | grep -q "/srv/osv-v2/osv/build" && kill $p; done; }
LOCS="C C.UTF-8 en_US.UTF-8 en_GB.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 es_ES.UTF-8 it_IT.UTF-8 pt_BR.UTF-8 nl_NL.UTF-8 sv_SE.UTF-8 pl_PL.UTF-8 ru_RU.UTF-8 ja_JP.UTF-8 zh_CN.UTF-8 ko_KR.UTF-8 tr_TR.UTF-8 fa_IR.UTF-8 ar_SA.UTF-8 my_MM.UTF-8"
G=/srv/osv-v2/s1a2
TAG=$1; shift
for what in "$@"; do case $what in
tld)
  guard tld; timeout 300 scripts/run.py -e "/tests/tst-locale-data.so" > $C/$TAG.tld.raw 2>&1; r=$?; reap
  say "  TLD $TAG rc=$r $(tr -d '\r' < $C/$TAG.tld.raw | grep -a 'SUMMARY' | head -1) fails: $(tr -d '\r' < $C/$TAG.tld.raw | grep -a '^FAIL' | head -3 | tr '\n' '|')" ;;
dump)
  for mode in dir arch; do D=$C/$TAG.dump-$mode; mkdir -p $D
    for l in $LOCS; do guard dump-$l
      if [ $mode = dir ]; then env="--env=LOCPATH=/usr/share/osv-locale-test/dir"; else env=""; fi
      timeout 120 scripts/run.py -e "$env /tests/misc-locale-dump.so $l" > $D/$l.raw 2>&1; r=$?; reap
      tr -d '\r' < $D/$l.raw | grep -a '^@ ' > $D/$l.txt
      n=$(diff $G/gd/$l.txt $D/$l.txt | grep -c '^<')
      say "  DUMP $TAG $mode $l rc=$r lines=$(wc -l < $D/$l.txt) diff-vs-glibc-dir=$n"; done; done ;;
ctype)
  D=$C/$TAG.ctype; mkdir -p $D
  # misc-ctype-dump --sha256 hashes its 1114112-line dump in the guest (a 25 MB console is slow);
  # the hash equals sha256sum of the plain dump (checked against glibc's on the host).
  for l in $LOCS; do guard ctype-$l
    timeout 900 scripts/run.py -e "--env=LOCPATH=/usr/share/osv-locale-test/dir /tests/misc-ctype-dump.so --sha256 $l" > $D/$l.raw 2>&1; r=$?; reap
    h=$(tr -d '\r' < $D/$l.raw | grep -a "^sha256 $l " | cut -d' ' -f3)
    g=$(cat $G/cdump/g-$l.sha)
    say "  CTYPE $TAG $l rc=$r sha256=$h $([ -n "$h" ] && [ "$h" = "$g" ] && echo IDENTICAL || echo "DIFFERS glibc=$g")"; done ;;
esac; done
