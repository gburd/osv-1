#!/bin/bash
# ONE OSv cell, FRESH-BOOT-PER-CELL. SCALE RE-TEST version.
# ARGS: <vu> <rep> [durable|nondurable]
# Adds vs the a2a runcell:
#   - DRIVER-side instrumentation every cell (drvinstr.sh) + a DRIVER_VERDICT, so a
#     driver-limited cell is declared invalid instead of reported as an OSv result.
#   - the RESOLVED-LEVER PROOF pulled off the boot console and saved per cell (mandatory).
#   - the footprint probe's FPTOT sampled DURING the run -> per-backend MB at this VU
#     (the footprint fix's end-to-end test: ~10MB/backend, not ~250MB).
#   - a nondurable mode (fsync=off + synchronous_commit=off) for the #4 discriminator.
set -uo pipefail
. /home/gburd/ws/osv/.local/scale/env.sh
VU="$1"; REP="$2"; MODE="${3:-durable}"
SB="${SB:-16GB}"; MAXCONN="${MAXCONN:-400}"
TAG="osv-vu$VU-r$REP"
[ "$MODE" = nondurable ] && TAG="osv-nd-vu$VU-r$REP"
LOCAL=/home/gburd/ws/osv/.local/scale/cells
mkdir -p "$LOCAL"
PGH=$METALPRIV
SYNCCOMMIT=on; FSYNC=on
[ "$MODE" = nondurable ] && { SYNCCOMMIT=off; FSYNC=off; }

echo "=== CELL $TAG : mode=$MODE SB=$SB MAXCONN=$MAXCONN : FRESH BOOT ==="
timeout 20 ssh $SSHO $METAL "sudo setsid --fork sh -c 'pkill -9 -f \"qemu-system-x86_64 -M pc\"' </dev/null >/dev/null 2>&1; echo KILL_SENT" 2>&1 || true
for k in $(seq 1 15); do
  sleep 3
  R=$(timeout 20 ssh $SSHO $METAL "if sudo fuser /work/img-fix/usr.img >/dev/null 2>&1; then echo LOCKED; else echo FREE; fi" 2>&1)
  [ "$R" = FREE ] && { echo LOCK_FREE; break; }
done
timeout 20 ssh $SSHO $METAL "sudo TAG=fix SB=$SB MAXCONN=$MAXCONN SYNCCOMMIT=$SYNCCOMMIT FSYNC=$FSYNC FP_INTERVAL=10 setsid --fork bash /tmp/boot-osv.sh run </dev/null >/dev/null 2>&1; echo BOOTED" 2>&1

echo "=== CELL $TAG : wait for PG (tolerates crash recovery up to ~18min) ==="
up=0
for i in $(seq 1 180); do
  R=$(timeout 15 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=8 psql -h $PGH -U postgres -d tpcc -tAc 'select 1' 2>&1" 2>&1)
  echo "$R" | grep -q '^1$' && { echo "PG up after $i tries"; up=1; break; }
  [ $((i % 20)) -eq 0 ] && echo "  still waiting for PG (try $i): $(echo "$R"|tail -1)"
  sleep 6
done
if [ "$up" != 1 ]; then
  echo "CELL $TAG: PG DID NOT COME UP - abort cell"
  # POOL-IDENTITY CHECK FIRST. A cross-arm device mixup presents as a PG startup failure
  # ("data directory has wrong ownership") and would read as an OSv defect. The pool SIZE
  # is what actually names it: the OSv pool is ~19-25G with the 200wh schema, the Linux
  # pool is ~39G. Print it before anything else so the abort is diagnosable, not guessed.
  timeout 30 ssh $SSHO $METAL "sudo grep -aE 'pgdata +used|wrong ownership|ashift' /work/console-run.log | tail -5" 2>&1 | tee "$LOCAL/$TAG.poolcheck.txt"
  timeout 30 ssh $SSHO $METAL "sudo tail -40 /work/console-run.log" 2>&1 | tee "$LOCAL/$TAG.bootfail.txt"
  timeout 30 ssh $SSHO $METAL "sudo bash /tmp/leverproof.sh /work/console-run.log" 2>&1 | tee "$LOCAL/$TAG.leverproof.txt"
  exit 2
fi

# ---- MANDATORY: the resolved-lever proof, per arm, per cell, off the console ----
echo "=== CELL $TAG : RESOLVED-LEVER PROOF ==="
timeout 30 ssh $SSHO $METAL "sudo bash /tmp/leverproof.sh /work/console-run.log" 2>&1 | tee "$LOCAL/$TAG.leverproof.txt"
# resolved GUCs read back OUT OF THE RUNNING GUEST (not from the command line)
timeout 30 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=10 psql -h $PGH -U postgres -d tpcc -tAc \
 \"select name||'='||setting from pg_settings where name in ('io_method','shared_buffers','max_connections','fsync','synchronous_commit','wal_sync_method','effective_cache_size','max_wal_size')\" 2>&1" | tee "$LOCAL/$TAG.gucs.txt"

echo "=== CELL $TAG : hardened quiesce (2 consecutive sub-1s checkpoints) ==="
timeout 300 ssh $SSHO $DRV "bash /tmp/quiesce.sh $PGH 2>&1" | tee "$LOCAL/$TAG.quiesce.txt"

echo "=== CELL $TAG : start HOST instr (iostat + qemu-cpu + tap0) ==="
timeout 20 ssh $SSHO $METAL "sudo setsid --fork bash /tmp/instr.sh 420 $TAG </dev/null >/tmp/instr-$TAG.out 2>&1; echo HOST_INSTR" 2>&1
echo "=== CELL $TAG : start DRIVER instr (cpu/load/hdb-proc/NIC) ==="
timeout 20 ssh $SSHO $DRV "setsid --fork bash /tmp/drvinstr.sh 420 $TAG </dev/null >/tmp/drvinstr-$TAG.out 2>&1; echo DRV_INSTR" 2>&1
echo "=== CELL $TAG : start wait sampler ==="
timeout 20 ssh $SSHO $DRV "setsid --fork sh -c 'sleep 130; python3 /tmp/waithist.py $PGH 280 /tmp/waithist-$TAG.json' </dev/null >/tmp/wh-$TAG.out 2>&1; echo WH" 2>&1
# FPTOT sampler: capture the footprint probe's per-AS lines DURING the loaded window,
# so per-backend MB is measured at THIS VU, not at idle.
timeout 20 ssh $SSHO $METAL "sudo setsid --fork sh -c 'sleep 200; sudo grep -h FPTOT /work/console-run.log | tail -25 > /work/fptot-$TAG.txt' </dev/null >/dev/null 2>&1; echo FPTOT_SAMPLER" 2>&1

echo "=== CELL $TAG : run HammerDB (rampup2/dur5) ==="
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

echo "=== CELL $TAG : collect (NOPM + p99 + waits) ==="
sleep 5
timeout 40 ssh $SSHO $DRV "
echo '---NOPM/TPM---'; grep -E 'System achieved|TEST RESULT' /tmp/hdb-$TAG.log 2>/dev/null | tail -2
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

echo "=== CELL $TAG : HOST instr + qemu-cpu discriminator + regression watch ==="
timeout 60 ssh $SSHO $METAL "sleep 2
sudo cat /work/instr-$TAG.summary 2>/dev/null
echo '---qemu cpu ALL---'; sudo cat /work/qemucpu-$TAG.txt 2>/dev/null
echo '---qemu cpu DISCRIMINATOR---'; sudo python3 /tmp/qdisc.py $TAG 2>/dev/null
echo '---tap0 net---'; sudo cat /work/tap-$TAG.txt 2>/dev/null | tail -20
echo '---FOOTPRINT (FPTOT during run: per_as_KB is the per-backend number)---'
sudo cat /work/fptot-$TAG.txt 2>/dev/null | tail -6
echo '---FPTOT final---'; sudo grep -h FPTOT /work/console-run.log 2>/dev/null | tail -2
echo '---REGRESSION WATCH (EMFILE / OOM / dentry / panic)---'
sudo grep -icE 'Too many open files|EMFILE' /work/console-run.log 2>/dev/null | sed 's/^/EMFILE_COUNT=/'
sudo grep -icE 'Out of memory|could not reclaim|bad_alloc' /work/console-run.log 2>/dev/null | sed 's/^/OOM_COUNT=/'
sudo grep -icE 'abort|panic|Assertion failed' /work/console-run.log 2>/dev/null | sed 's/^/ABORT_COUNT=/'
sudo grep -iE 'Out of memory|could not reclaim|Too many open files|panic' /work/console-run.log 2>/dev/null | tail -3
" | tee "$LOCAL/$TAG.instr.txt"
# keep the whole console off-box for this cell (cheap, and the only OOM/lever evidence)
timeout 60 ssh $SSHO $METAL "sudo gzip -c /work/console-run.log" > "$LOCAL/$TAG.console.log.gz" 2>/dev/null

echo "=== CELL $TAG : clean poweroff (NEVER kill mid-CHECKPOINT) ==="
timeout 20 ssh $SSHO $DRV "pkill -9 -f hammerdbcli 2>/dev/null; pkill -9 -f 'run-$TAG.tcl' 2>/dev/null; echo HDB_CLIENTS_KILLED" 2>&1 || true
timeout 40 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=15 psql -h $PGH -U postgres -d tpcc -tAc \"select pg_terminate_backend(pid) from pg_stat_activity where pid<>pg_backend_pid() and backend_type='client backend'\" 2>&1 | tail -1" 2>&1 || true
sleep 2
timeout 420 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=15 psql -h $PGH -U postgres -d tpcc -c 'CHECKPOINT' 2>&1 | tail -1" 2>&1
timeout 120 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=15 psql -h $PGH -U postgres -d tpcc -c 'CHECKPOINT' 2>&1 | tail -1" 2>&1
timeout 30 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=15 psql -h $PGH -U postgres -d tpcc -tAc \"select count(*) from pg_stat_activity where state='active' and pid<>pg_backend_pid()\" 2>&1|tail -1" 2>&1
sleep 3
timeout 20 ssh $SSHO $METAL "sudo setsid --fork sh -c 'pkill -9 -f \"qemu-system-x86_64 -M pc\"' </dev/null >/dev/null 2>&1; echo KILL_SENT" 2>&1 || true
for k in $(seq 1 12); do
  sleep 4
  R=$(timeout 20 ssh $SSHO $METAL "ps -eo cmd | grep -c '[q]emu-system-x86_64 -M pc'" 2>/dev/null | tr -d '[:space:]')
  [ "$R" = 0 ] && { echo GUEST_DOWN; break; }
done
echo "=== CELL $TAG DONE ==="
