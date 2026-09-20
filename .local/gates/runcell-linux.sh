#!/bin/bash
# Drive ONE Linux (Ubuntu glibc) benchmark cell, FRESH-BOOT-PER-CELL, MATCHED to the OSv arm.
# ARGS: <vu> <rep>. Runs from the workstation.
# Fresh Ubuntu guest boot -> import ZFS pool + start PG (io_uring) -> quiesce -> instr+waits ->
# HammerDB cell -> collect (incl qemu-cpu discriminator) -> pg_ctl stop (clean) -> kill guest.
set -uo pipefail
. /home/gburd/ws/osv/.local/gates/env.sh
VU="$1"; REP="$2"
TAG="linux-vu$VU-r$REP"
LOCAL=/home/gburd/ws/osv/.local/gates/cells
mkdir -p "$LOCAL"
PGH=$METALPRIV
GK="-i /tmp/gk -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
GUEST=ubuntu@192.168.100.2

echo "=== CELL $TAG : FRESH BOOT (Ubuntu) ==="
timeout 40 ssh $SSHO $METAL "sudo pkill -9 -f 'qemu-system-x86_64 -M pc' 2>/dev/null; for i in \$(seq 1 20); do sudo fuser /work/ubuntu.qcow2 >/dev/null 2>&1 || break; sleep 1; done; echo KILLED" 2>&1
timeout 20 ssh $SSHO $METAL "sudo setsid --fork bash /tmp/boot-ubuntu.sh </dev/null >/dev/null 2>&1; echo BOOTED" 2>&1

echo "=== CELL $TAG : wait for guest SSH ==="
gup=0
for i in $(seq 1 40); do
  R=$(timeout 15 ssh $SSHO $METAL "timeout 8 ssh $GK $GUEST 'echo up' 2>&1" 2>&1)
  echo "$R" | grep -q '^up$' && { echo "guest ssh up (try $i)"; gup=1; break; }
  sleep 6
done
[ "$gup" = 1 ] || { echo "CELL $TAG: guest SSH never came up - abort"; exit 2; }

echo "=== CELL $TAG : re-push gstart.sh (guest /tmp is wiped each fresh boot) ==="
timeout 30 ssh $SSHO $METAL "scp $GK /tmp/gstart.sh $GUEST:/tmp/gstart.sh 2>&1|tail -1; echo PUSHED" 2>&1

echo "=== CELL $TAG : start PG (io_uring) via metal-side nohup launcher ==="
timeout 20 ssh $SSHO $METAL "nohup ssh $GK $GUEST 'bash /tmp/gstart.sh' </dev/null >/tmp/gstart-metal.log 2>&1 & echo PG_LAUNCH" 2>&1

echo "=== CELL $TAG : wait for PG (tolerates recovery up to ~18min) ==="
up=0
for i in $(seq 1 180); do
  R=$(timeout 15 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=8 psql -h $PGH -U postgres -d tpcc -tAc 'select 1' 2>&1" 2>&1)
  echo "$R" | grep -q '^1$' && { echo "PG up (try $i)"; up=1; break; }
  [ $((i % 20)) -eq 0 ] && echo "  still waiting for PG (try $i)"
  sleep 6
done
[ "$up" = 1 ] || { echo "CELL $TAG: PG never came up - abort"; timeout 15 ssh $SSHO $METAL "timeout 8 ssh $GK $GUEST 'sudo tail -15 /data/pg/startup.log' 2>&1"; exit 2; }

timeout 20 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=10 psql -h $PGH -U postgres -d tpcc -tAc 'show io_method' 2>&1" | tee "$LOCAL/$TAG.iomethod.txt"

echo "=== CELL $TAG : hardened quiesce ==="
timeout 300 ssh $SSHO $DRV "bash /tmp/quiesce.sh $PGH 2>&1" | tee "$LOCAL/$TAG.quiesce.txt"

echo "=== CELL $TAG : start host instr (iostat nvme1n1 + qemu cpu) ==="
timeout 20 ssh $SSHO $METAL "sudo setsid --fork bash /tmp/instr.sh 420 $TAG </dev/null >/tmp/instr-$TAG.out 2>&1; echo INSTR" 2>&1
echo "=== CELL $TAG : start wait sampler ==="
timeout 20 ssh $SSHO $DRV "setsid --fork sh -c 'sleep 130; python3 /tmp/waithist.py $PGH 280 /tmp/waithist-$TAG.json' </dev/null >/tmp/wh.out 2>&1; echo WH" 2>&1

echo "=== CELL $TAG : run HammerDB ==="
timeout 20 ssh $SSHO $DRV "cd /tmp && setsid --fork bash /tmp/hdb.sh run $PGH $VU $TAG </dev/null >/tmp/hdbdrive-$TAG.out 2>&1; echo HDB_DETACHED" 2>&1
# poll for the run to finish (7min run + up to 6min gather cap)
done=0
for i in $(seq 1 90); do
  R=$(timeout 15 ssh $SSHO $DRV "grep -c 'TEST RESULT' /tmp/hdb-$TAG.log 2>/dev/null" 2>&1)
  echo "$R" | grep -q '^1$' && { echo "run complete (poll $i)"; done=1; break; }
  sleep 10
done

echo "=== CELL $TAG : collect ==="
sleep 5
timeout 40 ssh $SSHO $DRV "
echo '---NOPM/TPM---'; grep -E 'System achieved|TEST RESULT' /tmp/hdb-$TAG.log 2>/dev/null|tail -1
echo '---p99---'; python3 -c \"
import re,statistics as s
try: txt=open('/tmp/hdbxtprofile.log').read()
except: txt=''
p=[float(m.group(1)) for b in txt.split('PROC: NEWORD')[1:] for m in [re.search(r'P99:\\\\s*([0-9.]+)ms',b[:200])] if m]
print('NEWORD_p99 median=%.2f n=%d'%(s.median(p),len(p)) if p else 'p99 none')
\"
echo '---waits---'; cat /tmp/waithist-$TAG.json 2>/dev/null|python3 -c 'import json,sys;print(json.load(sys.stdin).get(\"pct\",{}))' 2>/dev/null
" | tee "$LOCAL/$TAG.result.txt"
timeout 30 ssh $SSHO $DRV "cat /tmp/hdbxtprofile.log 2>/dev/null" > "$LOCAL/$TAG.xtprof.txt" 2>/dev/null

echo "=== CELL $TAG : host instr (qemu-cpu discriminator) ==="
timeout 40 ssh $SSHO $METAL "sleep 2; sudo cat /work/instr-$TAG.summary 2>/dev/null; echo '---qemu cpu ALL---'; sudo cat /work/qemucpu-$TAG.txt 2>/dev/null; echo '---qemu cpu DISCRIMINATOR---'; sudo python3 /tmp/qdisc.py $TAG 2>/dev/null" | tee "$LOCAL/$TAG.instr.txt"

echo "=== CELL $TAG : clean PG stop (pg_ctl -m fast) then kill guest ==="
timeout 20 ssh $SSHO $DRV "pkill -9 -f hammerdbcli 2>/dev/null; pkill -9 -f 'run-$TAG.tcl' 2>/dev/null; echo HDB_CLIENTS_KILLED" 2>&1 || true
timeout 120 ssh $SSHO $METAL "timeout 90 ssh $GK $GUEST 'sudo -u postgres /usr/lib/postgresql/18/bin/pg_ctl -D /data/pg -m fast -w -t 90 stop 2>&1|tail -2' 2>&1" 2>&1
sleep 3
# detach kill (killing qemu drops this ssh on this metal); poll qemu-count separately
timeout 20 ssh $SSHO $METAL "sudo setsid --fork sh -c 'pkill -9 -f \"qemu-system-x86_64 -M pc\"' </dev/null >/dev/null 2>&1; echo KILL_SENT" 2>&1 || true
for k in $(seq 1 12); do
  sleep 4
  R=$(timeout 20 ssh $SSHO $METAL "ps -eo cmd | grep -c '[q]emu-system-x86_64 -M pc'" 2>/dev/null | tr -d '[:space:]')
  [ "$R" = 0 ] && { echo GUEST_DOWN; break; }
done
echo "=== CELL $TAG DONE ==="
