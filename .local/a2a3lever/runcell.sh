#!/bin/bash
# Drive ONE benchmark cell end-to-end from the workstation.
# quiesce -> start instr(host)+waithist(driver) -> run HammerDB timed + probe -> pull results local.
# ARGS: <os: osv|linux> <vu> <rep>
set -uo pipefail
. /home/gburd/ws/osv/.local/a2a3lever/env.sh
OS="$1"; VU="$2"; REP="$3"
TAG="$OS-vu$VU-$REP"
LOCAL=/home/gburd/ws/osv/.local/a2a3lever/cells
mkdir -p "$LOCAL"
# both arms serve PG on 172.31.0.8:5432 (DNAT to 192.168.100.2 guest)
PGH=$METALPRIV

echo "=== CELL $TAG : quiesce ==="
timeout 300 ssh $SSHO $DRV "bash /tmp/quiesce.sh $PGH 2>&1" | tee "$LOCAL/$TAG.quiesce.txt"

echo "=== CELL $TAG : start host instr (iostat+qemu cpu, 300s) ==="
timeout 20 ssh $SSHO $METAL "nohup bash /tmp/instr.sh 300 $TAG >/tmp/instr-$TAG.out 2>&1 & echo INSTR_PID=\$!"

echo "=== CELL $TAG : start waithist sampler on driver (starts after rampup, 300s window) ==="
timeout 20 ssh $SSHO $DRV "nohup sh -c 'sleep 130; python3 /tmp/waithist.py $PGH 280 /tmp/waithist-$TAG.json' >/tmp/waithist-$TAG.out 2>&1 & echo WAITHIST_PID=\$!"

echo "=== CELL $TAG : run HammerDB timed (rampup2/dur5) + connect probe ==="
timeout 800 ssh $SSHO $DRV "bash /tmp/cell.sh $PGH $VU $TAG 2>&1" | tee "$LOCAL/$TAG.cell.txt"

echo "=== CELL $TAG : collect ==="
sleep 5
timeout 30 ssh $SSHO $DRV "cat /tmp/probe-$TAG.json 2>/dev/null; echo '---waithist---'; cat /tmp/waithist-$TAG.json 2>/dev/null; echo '---NOPM---'; grep -E 'System achieved|NOPM|TEST RESULT' /tmp/hdb-$TAG.log 2>/dev/null | tail -3" | tee "$LOCAL/$TAG.result.txt"
echo "---host instr---"
timeout 30 ssh $SSHO $METAL "sleep 2; grep -E 'util|w_await|qemu_cpu' /tmp/instr-$TAG.out 2>/dev/null; python3 - <<'PY' 2>/dev/null
import re,statistics as s
rows=[];hdr=None
try:
  for ln in open('/work/iostat-$TAG.txt'):
    f=ln.split()
    if not f:continue
    if f[0]=='Device':hdr=f;continue
    if hdr and f[0].startswith('nvme'):
      d=dict(zip(hdr,f));rows.append((float(d.get('%util',0)),float(d.get('w_await',0)),float(d.get('aqu-sz',0))))
  rows=rows[1:] or rows
  for i,n in enumerate(['%util','w_await','aqu-sz']):
    v=[r[i] for r in rows]
    if v:print(f'{n}: median={s.median(v):.2f} max={max(v):.2f}')
except Exception as e:print('iostat parse:',e)
PY
cat /work/qemucpu-$TAG.txt 2>/dev/null | tail -3" | tee "$LOCAL/$TAG.instr.txt"
echo "=== CELL $TAG DONE ==="
