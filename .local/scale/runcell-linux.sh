#!/bin/bash
# ONE Linux (Ubuntu glibc) cell, FRESH-BOOT-PER-CELL, MATCHED to the OSv arm.
# ARGS: <vu> <rep> [durable|nondurable]
# Same additions as the OSv runcell: driver-side instrumentation + DRIVER_VERDICT,
# resolved-lever proof per arm, per-backend memory (from the guest's own RSS accounting).
set -uo pipefail
. /home/gburd/ws/osv/.local/scale/env.sh
VU="$1"; REP="$2"; MODE="${3:-durable}"
SB="${SB:-16GB}"; MAXCONN="${MAXCONN:-400}"
TAG="linux-vu$VU-r$REP"
[ "$MODE" = nondurable ] && TAG="linux-nd-vu$VU-r$REP"
LOCAL=/home/gburd/ws/osv/.local/scale/cells
mkdir -p "$LOCAL"
PGH=$METALPRIV
GK="-i /tmp/gk -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
GUEST=ubuntu@192.168.100.2
SYNCCOMMIT=on; FSYNC=on
[ "$MODE" = nondurable ] && { SYNCCOMMIT=off; FSYNC=off; }

echo "=== CELL $TAG : mode=$MODE SB=$SB : FRESH BOOT (Ubuntu) ==="
timeout 40 ssh $SSHO $METAL "sudo pkill -9 -f 'qemu-system-x86_64 -M pc' 2>/dev/null; for i in \$(seq 1 20); do sudo fuser /work/ubuntu.qcow2 >/dev/null 2>&1 || break; sleep 1; done; echo KILLED" 2>&1
timeout 20 ssh $SSHO $METAL "sudo setsid --fork bash /work/boot-ubuntu.sh </dev/null >/dev/null 2>&1; echo BOOTED" 2>&1

echo "=== CELL $TAG : wait for guest SSH ==="
gup=0
for i in $(seq 1 40); do
  R=$(timeout 15 ssh $SSHO $METAL "timeout 8 ssh $GK $GUEST 'echo up' 2>&1" 2>&1)
  echo "$R" | grep -q '^up$' && { echo "guest ssh up (try $i)"; gup=1; break; }
  sleep 6
done
[ "$gup" = 1 ] || { echo "CELL $TAG: guest SSH never came up - abort"; exit 2; }

timeout 30 ssh $SSHO $METAL "scp $GK /work/linux-pg-start.sh $GUEST:/tmp/gstart.sh 2>&1|tail -1; echo PUSHED" 2>&1
echo "=== CELL $TAG : start PG (io_uring, SB=$SB sync=$SYNCCOMMIT fsync=$FSYNC) ==="
timeout 30 ssh $SSHO $METAL "nohup ssh $GK $GUEST 'SB=$SB MAXCONN=$MAXCONN SYNCCOMMIT=$SYNCCOMMIT FSYNC=$FSYNC bash /tmp/gstart.sh' </dev/null >/tmp/gstart-$TAG.log 2>&1 & echo PG_LAUNCH" 2>&1

echo "=== CELL $TAG : wait for PG ==="
up=0
for i in $(seq 1 180); do
  R=$(timeout 15 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=8 psql -h $PGH -U postgres -d tpcc -tAc 'select 1' 2>&1" 2>&1)
  echo "$R" | grep -q '^1$' && { echo "PG up (try $i)"; up=1; break; }
  [ $((i % 20)) -eq 0 ] && echo "  still waiting for PG (try $i)"
  sleep 6
done
if [ "$up" != 1 ]; then
  echo "CELL $TAG: PG never came up - abort"
  timeout 20 ssh $SSHO $METAL "cat /tmp/gstart-$TAG.log 2>/dev/null | tail -30" 2>&1 | tee "$LOCAL/$TAG.bootfail.txt"
  exit 2
fi

echo "=== CELL $TAG : RESOLVED-LEVER PROOF (Linux arm) ==="
timeout 30 ssh $SSHO $METAL "sed -n '/LINUX RESOLVED-LEVER PROOF/,/END LINUX LEVER PROOF/p' /tmp/gstart-$TAG.log 2>/dev/null" | tee "$LOCAL/$TAG.leverproof.txt"
timeout 30 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=10 psql -h $PGH -U postgres -d tpcc -tAc \
 \"select name||'='||setting from pg_settings where name in ('io_method','shared_buffers','max_connections','fsync','synchronous_commit','wal_sync_method','effective_cache_size','max_wal_size')\" 2>&1" | tee "$LOCAL/$TAG.gucs.txt"

echo "=== CELL $TAG : hardened quiesce ==="
timeout 300 ssh $SSHO $DRV "bash /tmp/quiesce.sh $PGH 2>&1" | tee "$LOCAL/$TAG.quiesce.txt"

echo "=== CELL $TAG : start HOST instr ==="
timeout 20 ssh $SSHO $METAL "sudo setsid --fork bash /tmp/instr.sh 420 $TAG nvme3n1 </dev/null >/tmp/instr-$TAG.out 2>&1; echo HOST_INSTR" 2>&1
echo "=== CELL $TAG : start DRIVER instr ==="
timeout 20 ssh $SSHO $DRV "setsid --fork bash /tmp/drvinstr.sh 420 $TAG </dev/null >/tmp/drvinstr-$TAG.out 2>&1; echo DRV_INSTR" 2>&1
echo "=== CELL $TAG : start wait sampler ==="
timeout 20 ssh $SSHO $DRV "setsid --fork sh -c 'sleep 130; python3 /tmp/waithist.py $PGH 280 /tmp/waithist-$TAG.json' </dev/null >/tmp/wh-$TAG.out 2>&1; echo WH" 2>&1
# Linux per-backend memory, the matched counterpart to OSv's FPTOT: sum of PRIVATE
# (Pss-shared-excluded) RSS across client backends, sampled mid-run.
timeout 20 ssh $SSHO $METAL "sudo setsid --fork bash -c 'sleep 200; ssh $GK $GUEST \"bash /tmp/pbmem.sh\" > /work/pbmem-$TAG.txt 2>&1' </dev/null >/dev/null 2>&1; echo PBMEM_SAMPLER" 2>&1

echo "=== CELL $TAG : run HammerDB ==="
timeout 20 ssh $SSHO $DRV "cd /tmp && setsid --fork bash /tmp/hdb.sh run $PGH $VU $TAG </dev/null >/tmp/hdbdrive-$TAG.out 2>&1; echo HDB_DETACHED" 2>&1
for i in $(seq 1 100); do
  R=$(timeout 15 ssh $SSHO $DRV "grep -c 'TEST RESULT' /tmp/hdb-$TAG.log 2>/dev/null || echo 0" 2>&1)
  echo "  hdb poll $i: TEST_RESULT=$R"
  echo "$R" | grep -qE '^1$' && { echo "run complete (poll $i)"; break; }
  sleep 10
done
# Collect the cell log. GREP THE TEST RESULT LINE EXPLICITLY, do not rely on tail -40:
# HammerDB keeps appending per-vuser output after the result line, so at high VU the result
# scrolls out of the last 40 lines and the cell reads as NOPM=NONE on a perfectly good run
# (this silently voided a valid Linux VU64 cell before it was caught and recovered).
timeout 20 ssh $SSHO $DRV "grep -a 'TEST RESULT' /tmp/hdb-$TAG.log 2>/dev/null; grep -a 'VUCOMPLETE_AFTER' /tmp/hdb-$TAG.log 2>/dev/null; tail -25 /tmp/hdb-$TAG.log 2>/dev/null" > "$LOCAL/$TAG.cell.txt" 2>/dev/null

echo "=== CELL $TAG : collect ==="
sleep 5
timeout 40 ssh $SSHO $DRV "
echo '---NOPM/TPM---'; grep -E 'System achieved|TEST RESULT' /tmp/hdb-$TAG.log 2>/dev/null|tail -2
echo '---VUCOMPLETE---'; grep VUCOMPLETE_AFTER /tmp/hdb-$TAG.log 2>/dev/null
echo '---NEWORD p99---'
python3 - <<'PY'
import re,statistics as s
try: txt=open('/tmp/hdbxtprofile.log').read()
except: txt=''
p=[float(m.group(1)) for b in txt.split('PROC: NEWORD')[1:] for m in [re.search(r'P99:\\s*([0-9.]+)ms',b[:200])] if m]
print('NEWORD_p99_ms median=%.3f min=%.3f max=%.3f nvu=%d'%(s.median(p),min(p),max(p),len(p)) if p else 'NEWORD_p99_ms NONE')
PY
echo '---wait profile---'; cat /tmp/waithist-$TAG.json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get(\"pct\",{}))[:600])' 2>/dev/null
" | tee "$LOCAL/$TAG.result.txt"
timeout 30 ssh $SSHO $DRV "cat /tmp/hdbxtprofile.log 2>/dev/null" > "$LOCAL/$TAG.xtprof.txt" 2>/dev/null

echo "=== CELL $TAG : DRIVER saturation verdict (cell validity) ==="
timeout 40 ssh $SSHO $DRV "cat /tmp/drvinstr-$TAG.summary 2>/dev/null || python3 /tmp/drvdisc.py $TAG 2>&1" | tee "$LOCAL/$TAG.drvinstr.txt"

echo "=== CELL $TAG : HOST instr + qemu-cpu + per-backend mem ==="
timeout 60 ssh $SSHO $METAL "sleep 2
sudo cat /work/instr-$TAG.summary 2>/dev/null
echo '---qemu cpu ALL---'; sudo cat /work/qemucpu-$TAG.txt 2>/dev/null
echo '---qemu cpu DISCRIMINATOR---'; sudo python3 /tmp/qdisc.py $TAG 2>/dev/null
echo '---tap0 net---'; sudo cat /work/tap-$TAG.txt 2>/dev/null|tail -20
echo '---PER-BACKEND MEM (Linux)---'; sudo cat /work/pbmem-$TAG.txt 2>/dev/null|tail -12
" | tee "$LOCAL/$TAG.instr.txt"

echo "=== CELL $TAG : clean PG stop then kill guest ==="
timeout 20 ssh $SSHO $DRV "pkill -9 -f hammerdbcli 2>/dev/null; pkill -9 -f 'run-$TAG.tcl' 2>/dev/null; echo HDB_CLIENTS_KILLED" 2>&1 || true
timeout 180 ssh $SSHO $METAL "timeout 150 ssh $GK $GUEST 'sudo -u postgres /usr/lib/postgresql/18/bin/pg_ctl -D /data/pg -m fast -w -t 140 stop 2>&1|tail -2' 2>&1" 2>&1
sleep 3
timeout 20 ssh $SSHO $METAL "sudo setsid --fork sh -c 'pkill -9 -f \"qemu-system-x86_64 -M pc\"' </dev/null >/dev/null 2>&1; echo KILL_SENT" 2>&1 || true
for k in $(seq 1 12); do
  sleep 4
  R=$(timeout 20 ssh $SSHO $METAL "ps -eo cmd | grep -c '[q]emu-system-x86_64 -M pc'" 2>/dev/null | tr -d '[:space:]')
  [ "$R" = 0 ] && { echo GUEST_DOWN; break; }
done
echo "=== CELL $TAG DONE ==="
