#!/bin/bash
# JOB D clean A/B: keep MANY backends connected via READ-ONLY pgbench (-S) load
# so DROP DATABASE's ProcSignalBarrier must signal them all, WITHOUT triggering
# the separate write-path EIO corruptor. Args: $1=iters $2=conc
set -u
HOST=192.168.100.2; PORT=5432
PSQL="psql -h $HOST -p $PORT -U postgres -d postgres -v ON_ERROR_STOP=1 -tA"
PGBENCH="pgbench -h $HOST -p $PORT -U postgres"
export PGCONNECT_TIMEOUT=10 PGPASSWORD=
ITERS="${1:-40}"; CONC="${2:-48}"
TAG="${TAG:-unfixed}"
alive() { timeout 8 $PSQL -c "SELECT 1;" >/dev/null 2>&1; }

echo "== JOB D CLEAN (RO-load) tag=$TAG iters=$ITERS conc=$CONC =="
# small scale so -i is quick and the RO working set fits shared_buffers (no write)
timeout 60 $PGBENCH -i -s 10 -d postgres >/mnt/nvme/wl-init.log 2>&1 || { echo "init FAIL"; tail -3 /mnt/nvme/wl-init.log; }
# READ-ONLY sustained load: CONC live backends, zero writes -> no checkpoint EIO
timeout $((ITERS*4 + 120)) $PGBENCH -S -c "$CONC" -j 8 -T $((ITERS*3 + 90)) -d postgres >/mnt/nvme/wl-ro.log 2>&1 &
PGB=$!
sleep 4
ok=0; hang=0; crash_iter=0
for i in $(seq 1 "$ITERS"); do
  # DROP DATABASE broadcasts ProcSignalBarrier to ALL CONC backends.
  if timeout 30 $PSQL -c "CREATE DATABASE cdbx$i TEMPLATE template0;" >/mnt/nvme/it.log 2>&1 \
     && timeout 30 $PSQL -c "DROP DATABASE cdbx$i;" >>/mnt/nvme/it.log 2>&1; then
    ok=$((ok+1)); echo "iter $i: CREATE+DROP OK (ok=$ok)"
  else
    echo "iter $i: op FAILED"; tail -3 /mnt/nvme/it.log
    if ! alive; then
      echo "iter $i: PG DEAD (crash)"; crash_iter=$i
      echo "==== JOB D CLEAN RESULT tag=$TAG: CRASH at iter $i, $ok clean before ===="; break
    fi
    # a DROP that timed out is a barrier hang (backend never acked)
    if grep -q "still waiting for backend" /mnt/nvme/it.log 2>/dev/null; then hang=$((hang+1)); fi
  fi
done
kill $PGB 2>/dev/null; wait 2>/dev/null
[ "$crash_iter" = 0 ] && echo "==== JOB D CLEAN RESULT tag=$TAG: $ok/$ITERS clean, hangs=$hang ===="
