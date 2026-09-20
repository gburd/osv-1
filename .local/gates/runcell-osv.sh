#!/bin/bash
# Drive ONE benchmark cell with FRESH-BOOT-PER-CELL discipline (OSv arm).
# ARGS: <vu> <rep>
# Runs from the workstation. Boots a fresh OSv guest, waits for PG, quiesces,
# starts host instr + wait sampler, runs the HammerDB cell, collects everything,
# then powers the guest off (each cell = its own boot; no multi-cell-per-boot).
# ARGS: <vu> <rep> [adapt]   adapt: 1 (default, adaptive-v2) | 0 (fixed) | 0:<spin> (fixed at <spin>)
set -uo pipefail
. /home/gburd/ws/osv/.local/gates/env.sh
VU="$1"; REP="$2"; ADAPTARG="${3:-1}"
# ADAPTARG forms: 1 -> adaptive; 0 -> fixed@10000; 0:N -> fixed@N
ADAPT="${ADAPTARG%%:*}"; FIXEDSPIN="${ADAPTARG#*:}"; [ "$FIXEDSPIN" = "$ADAPTARG" ] && FIXEDSPIN=10000
TAG="osv-vu$VU-r$REP"
[ "$ADAPT" = 0 ] && TAG="osv-vu$VU-fixed${FIXEDSPIN}-r$REP"
LOCAL=/home/gburd/ws/osv/.local/gates/cells
mkdir -p "$LOCAL"
PGH=$METALPRIV

echo "=== CELL $TAG : FRESH BOOT ==="
# kill any prior guest (detach: killing qemu drops this ssh on this metal), then wait for the
# usr.img lock to release in SEPARATE fresh ssh polls.
timeout 20 ssh $SSHO $METAL "sudo setsid --fork sh -c 'pkill -9 -f \"qemu-system-x86_64 -M pc\"' </dev/null >/dev/null 2>&1; echo KILL_SENT" 2>&1 || true
for k in $(seq 1 15); do
  sleep 3
  R=$(timeout 20 ssh $SSHO $METAL "if sudo fuser /work/osv/build/last/usr.img >/dev/null 2>&1; then echo LOCKED; else echo FREE; fi" 2>&1)
  [ "$R" = FREE ] && { echo LOCK_FREE; break; }
done
timeout 20 ssh $SSHO $METAL "sudo ADAPT=$ADAPT FIXEDSPIN=$FIXEDSPIN setsid --fork bash /tmp/boot-osv.sh run </dev/null >/dev/null 2>&1; echo BOOTED" 2>&1
echo "CELL $TAG : ADAPT=$ADAPT FIXEDSPIN=$FIXEDSPIN"

# wait for PG to accept connections. A fresh import is fast, BUT if the PREVIOUS cell's run was
# a HammerDB gather-hang, its qemu was killed with unreplayed WAL, so THIS boot does crash recovery
# (measured up to ~13min redo + a ~2.5min end-of-recovery checkpoint on the 200wh pool). Tolerate
# that: 180 tries x 6s = 18min, and treat "not yet accepting connections" as "still recovering".
echo "=== CELL $TAG : wait for PG (tolerates crash recovery up to ~18min) ==="
up=0
for i in $(seq 1 180); do
  R=$(timeout 15 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=8 psql -h $PGH -U postgres -d tpcc -tAc 'select 1' 2>&1" 2>&1)
  if echo "$R" | grep -q '^1$'; then echo "PG up after ${i} tries"; up=1; break; fi
  # heartbeat every ~2min so the log shows recovery progress, not a silent stall
  [ $((i % 20)) -eq 0 ] && echo "  still waiting for PG (try $i): $(echo "$R" | tail -1)"
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

echo "=== CELL $TAG : run HammerDB timed (rampup2/dur5), detached+poll (robust to ssh drop) ==="
timeout 20 ssh $SSHO $DRV "cd /tmp && setsid --fork bash /tmp/hdb.sh run $PGH $VU $TAG </dev/null >/tmp/hdbdrive-$TAG.out 2>&1; echo HDB_DETACHED" 2>&1
# poll for TEST RESULT (rampup 2 + timed 5 = ~7min, + up to 6min gather cap)
for i in $(seq 1 100); do
  R=$(timeout 15 ssh $SSHO $DRV "grep -c 'TEST RESULT' /tmp/hdb-$TAG.log 2>/dev/null || echo 0" 2>&1)
  echo "  hdb poll $i: TEST_RESULT=$R"
  echo "$R" | grep -qE '^1$' && { echo "run complete (poll $i)"; break; }
  sleep 10
done
timeout 20 ssh $SSHO $DRV "cat /tmp/hdb-$TAG.log 2>/dev/null | tail -40" > "$LOCAL/$TAG.cell.txt" 2>/dev/null

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
timeout 40 ssh $SSHO $METAL "sleep 2; sudo cat /work/instr-$TAG.summary 2>/dev/null; echo '---qemu cpu ALL samples---'; sudo cat /work/qemucpu-$TAG.txt 2>/dev/null; echo '---qemu cpu DISCRIMINATOR---'; sudo python3 /tmp/qdisc.py $TAG 2>/dev/null; echo '---mem/leak check---'; sudo grep -iE 'Out of memory|OOM|bad_alloc|EMFILE|Too many open' /work/console-run.log 2>/dev/null | tail -5 || echo NO_LEAK_MARKERS" | tee "$LOCAL/$TAG.instr.txt"

echo "=== CELL $TAG : power off guest (fresh-boot discipline) ==="
# CRITICAL: a SIGKILL that races an in-flight checkpoint corrupts the ZFS-backed pool
# (ZIL/mount abort on next import) AND leaves unreplayed WAL that forces a multi-minute crash
# recovery on the NEXT boot. So FIRST stop new WAL: kill any lingering HammerDB clients on the
# driver, then terminate active backends, THEN CHECKPOINT to completion x2 (quiescent), only THEN
# kill qemu. Never kill mid-checkpoint. This is what prevents a gather-hang cell from cascading.
timeout 20 ssh $SSHO $DRV "pkill -9 -f hammerdbcli 2>/dev/null; pkill -9 -f 'run-$TAG.tcl' 2>/dev/null; echo HDB_CLIENTS_KILLED" 2>&1 || true
timeout 30 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=15 psql -h $PGH -U postgres -d tpcc -tAc \"select pg_terminate_backend(pid) from pg_stat_activity where pid<>pg_backend_pid() and backend_type='client backend'\" 2>&1 | tail -1" 2>&1 || true
sleep 2
timeout 420 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=15 psql -h $PGH -U postgres -d tpcc -c 'CHECKPOINT' 2>&1 | tail -1" 2>&1
timeout 120 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=15 psql -h $PGH -U postgres -d tpcc -c 'CHECKPOINT' 2>&1 | tail -1" 2>&1
# confirm PG is idle (no active backend but self) so nothing is writing when we kill
timeout 30 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=15 psql -h $PGH -U postgres -d tpcc -tAc \"select count(*) from pg_stat_activity where state='active' and pid<>pg_backend_pid()\" 2>&1 | tail -1" 2>&1
sleep 3
# HARDENED: killing qemu (with its tap device) reliably drops THIS ssh session on this metal,
# so detach the pkill and poll qemu-count in SEPARATE fresh ssh calls with retries.
timeout 20 ssh $SSHO $METAL "sudo setsid --fork sh -c 'pkill -9 -f \"qemu-system-x86_64 -M pc\"' </dev/null >/dev/null 2>&1; echo KILL_SENT" 2>&1 || true
down=0
for k in $(seq 1 12); do
  sleep 4
  R=$(timeout 20 ssh $SSHO $METAL "ps -eo cmd | grep -c '[q]emu-system-x86_64 -M pc'" 2>/dev/null | tr -d '[:space:]')
  echo "  poweroff poll $k: qemu=$R"
  [ "$R" = 0 ] && { down=1; echo GUEST_DOWN; break; }
done
[ "$down" = 1 ] || echo "WARN: guest may still be up after poweroff polls"
echo "=== CELL $TAG DONE ==="
