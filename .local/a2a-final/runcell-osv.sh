#!/bin/bash
# Drive ONE benchmark cell with FRESH-BOOT-PER-CELL discipline (OSv arm).
# ARGS: <vu> <rep>
# Runs from the workstation. Boots a fresh OSv guest, waits for PG, quiesces,
# starts host instr + wait sampler, runs the HammerDB cell, collects everything,
# then powers the guest off (each cell = its own boot; no multi-cell-per-boot).
set -uo pipefail
. /home/gburd/ws/osv/.local/a2a-final/env.sh
VU="$1"; REP="$2"
TAG="osv-vu$VU-r$REP"
LOCAL=/home/gburd/ws/osv/.local/a2a-final/cells
mkdir -p "$LOCAL"
PGH=$METALPRIV

echo "=== CELL $TAG : FRESH BOOT ==="
# kill any prior guest; then require the usr.img write lock to be RELEASED and stay released
# (SIGKILL on a busy 32-vCPU qemu with pending NVMe aio releases the flock only after reap).
timeout 60 ssh $SSHO $METAL "sudo pkill -9 -f 'qemu-system-x86_64 -M pc' 2>/dev/null; sleep 4; free=0; for i in \$(seq 1 30); do if sudo fuser /work/osv/build/last/usr.img >/dev/null 2>&1; then free=0; else free=\$((free+1)); fi; [ \$free -ge 2 ] && break; sleep 1; done; sudo fuser /work/osv/build/last/usr.img >/dev/null 2>&1 && echo LOCK_STILL_HELD || echo LOCK_FREE" 2>&1
timeout 20 ssh $SSHO $METAL "sudo setsid --fork bash /tmp/boot-osv.sh run </dev/null >/dev/null 2>&1; echo BOOTED" 2>&1

# wait for PG to accept connections (fresh import + start)
echo "=== CELL $TAG : wait for PG ==="
up=0
for i in $(seq 1 90); do
  R=$(timeout 15 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=8 psql -h $PGH -U postgres -d tpcc -tAc 'select 1' 2>&1" 2>&1)
  if echo "$R" | grep -q '^1$'; then echo "PG up after ${i} tries"; up=1; break; fi
  sleep 6
done
[ "$up" = 1 ] || { echo "CELL $TAG: PG DID NOT COME UP - abort cell"; timeout 20 ssh $SSHO $METAL "sudo tail -20 /work/console-run.log"; exit 2; }

# confirm io_method still io_uring + no EMFILE / OOM leak markers pre-run
timeout 20 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=10 psql -h $PGH -U postgres -d tpcc -tAc 'show io_method' 2>&1" | tee "$LOCAL/$TAG.iomethod.txt"

echo "=== CELL $TAG : hardened quiesce (2 consecutive sub-1s checkpoints) ==="
timeout 300 ssh $SSHO $DRV "bash /tmp/quiesce.sh $PGH 2>&1" | tee "$LOCAL/$TAG.quiesce.txt"

echo "=== CELL $TAG : start host instr (iostat nvme1n1 + qemu cpu, 420s) ==="
timeout 20 ssh $SSHO $METAL "sudo setsid --fork bash /tmp/instr.sh 420 $TAG </dev/null >/tmp/instr-$TAG.out 2>&1; echo INSTR_STARTED" 2>&1

echo "=== CELL $TAG : start wait-profile sampler on driver (after rampup) ==="
timeout 20 ssh $SSHO $DRV "setsid --fork sh -c 'sleep 130; python3 /tmp/waithist.py $PGH 280 /tmp/waithist-$TAG.json' </dev/null >/tmp/waithist-$TAG.out 2>&1; echo WAITHIST_STARTED" 2>&1

echo "=== CELL $TAG : run HammerDB timed (rampup2/dur5) ==="
timeout 800 ssh $SSHO $DRV "cd /tmp && bash /tmp/hdb.sh run $PGH $VU $TAG 2>&1" | tee "$LOCAL/$TAG.cell.txt"

echo "=== CELL $TAG : collect ==="
sleep 5
timeout 40 ssh $SSHO $DRV "
echo '---NOPM/TPM---'; grep -E 'System achieved|TEST RESULT' /tmp/hdb-$TAG.log 2>/dev/null | tail -2
echo '---VUCOMPLETE---'; grep VUCOMPLETE_AFTER /tmp/hdb-$TAG.log 2>/dev/null
echo '---NEWORD p99 (median across vusers from hdbxtprofile)---'
python3 - <<'PY'
import re,statistics as s
try:
  txt=open('/tmp/hdbxtprofile.log').read()
except: txt=''
blocks=txt.split('PROC: NEWORD')
p99=[]
for b in blocks[1:]:
  m=re.search(r'P99:\\s*([0-9.]+)ms', b[:200])
  if m: p99.append(float(m.group(1)))
if p99:
  print('NEWORD_p99_ms median=%.3f min=%.3f max=%.3f nvu=%d'%(s.median(p99),min(p99),max(p99),len(p99)))
else:
  print('NEWORD_p99_ms NONE')
PY
echo '---wait profile---'; cat /tmp/waithist-$TAG.json 2>/dev/null
" | tee "$LOCAL/$TAG.result.txt"
# save the raw xtprofile off-box immediately
timeout 30 ssh $SSHO $DRV "cat /tmp/hdbxtprofile.log 2>/dev/null" > "$LOCAL/$TAG.xtprof.txt" 2>/dev/null

echo "=== CELL $TAG : host instr summary ==="
timeout 40 ssh $SSHO $METAL "sleep 2; sudo cat /work/instr-$TAG.summary 2>/dev/null; echo '---qemu cpu---'; sudo cat /work/qemucpu-$TAG.txt 2>/dev/null | tail -6; echo '---mem/leak check: OOM or monotonic drop?---'; sudo grep -iE 'Out of memory|OOM|bad_alloc|EMFILE|Too many open' /work/console-run.log 2>/dev/null | tail -5 || echo NO_LEAK_MARKERS" | tee "$LOCAL/$TAG.instr.txt"

echo "=== CELL $TAG : power off guest (fresh-boot discipline) ==="
# CRITICAL: a SIGKILL that races an in-flight checkpoint corrupts the ZFS-backed pool
# (ZIL/mount abort on next import). So: CHECKPOINT to completion, then a SECOND fast
# CHECKPOINT that MUST return quickly (proves the first fully flushed and the redo pointer
# advanced with NO write in flight), then settle, only THEN kill. Never kill mid-checkpoint.
timeout 420 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=15 psql -h $PGH -U postgres -d tpcc -c 'CHECKPOINT' 2>&1 | tail -1" 2>&1
timeout 120 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=15 psql -h $PGH -U postgres -d tpcc -c 'CHECKPOINT' 2>&1 | tail -1" 2>&1
# confirm PG is idle (no active backend but self) so nothing is writing when we kill
timeout 30 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=15 psql -h $PGH -U postgres -d tpcc -tAc \"select count(*) from pg_stat_activity where state='active' and pid<>pg_backend_pid()\" 2>&1 | tail -1" 2>&1
sleep 3
timeout 25 ssh $SSHO $METAL "sudo pkill -9 -f 'qemu-system-x86_64 -M pc' 2>/dev/null; sleep 6; sudo fuser /work/osv/build/last/usr.img >/dev/null 2>&1 && echo STILL_LOCKED || echo GUEST_DOWN" 2>&1
echo "=== CELL $TAG DONE ==="
