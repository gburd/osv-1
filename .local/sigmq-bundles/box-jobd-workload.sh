#!/bin/bash
# JOB D reproduction: hammer DROP DATABASE while MANY backends are connected +
# under pgbench load, so ProcSignalBarrier must SIGUSR1-signal all of them.
# The ~1-in-3 crash = a spawned SIGUSR1 handler thread faults in the backend COW
# AS ("exception nested too deeply"). Args: $1=iterations $2=concurrency
set -u
HOST=192.168.100.2; PORT=5432
PSQL="psql -h $HOST -p $PORT -U postgres -d postgres -v ON_ERROR_STOP=1 -tA"
PGBENCH="pgbench -h $HOST -p $PORT -U postgres"
export PGCONNECT_TIMEOUT=10 PGPASSWORD=
ITERS="${1:-60}"; CONC="${2:-48}"
TAG="${TAG:-unfixed}"

alive() { timeout 8 $PSQL -c "SELECT 1;" >/dev/null 2>&1; }

echo "== JOB D workload tag=$TAG iters=$ITERS conc=$CONC =="
# Prep load DB 'a' (small pgbench scale so init is quick)
timeout 60 $PGBENCH -i -s 10 -d postgres >/mnt/nvme/wl-init.log 2>&1 || { echo "pgbench init FAIL"; tail -5 /mnt/nvme/wl-init.log; }

# Background: sustained pgbench load on db 'a' (postgres db) with CONC clients =
# CONC live backends the DROP-DATABASE barrier must signal.
timeout $((ITERS*6 + 120)) $PGBENCH -c "$CONC" -j 8 -T $((ITERS*5 + 60)) -d postgres >/mnt/nvme/wl-pgbench.log 2>&1 &
PGB=$!
sleep 3
# Also hold a pool of idle-in-transaction connections open (extra barrier targets)
for k in $(seq 1 16); do
  ( timeout $((ITERS*6 + 60)) psql -h $HOST -p $PORT -U postgres -d postgres -c "SELECT pg_sleep($((ITERS*5 + 30)));" >/dev/null 2>&1 ) &
done

ok=0; crash_iter=0
for i in $(seq 1 "$ITERS"); do
  if timeout 45 $PSQL -c "CREATE DATABASE dbx$i TEMPLATE template0;" >/mnt/nvme/it.log 2>&1 \
     && timeout 45 $PSQL -c "DROP DATABASE dbx$i;" >>/mnt/nvme/it.log 2>&1; then
    ok=$((ok+1)); echo "iter $i: CREATE+DROP OK (ok=$ok)"
  else
    echo "iter $i: op FAILED"; tail -4 /mnt/nvme/it.log
    if ! alive; then
      echo "iter $i: PG DEAD (crash)"; crash_iter=$i
      echo "==== JOB D RESULT tag=$TAG: CRASH at iter $i, $ok/$ITERS clean before crash ===="
      break
    fi
  fi
done
kill $PGB 2>/dev/null; wait 2>/dev/null
if [ "$crash_iter" = 0 ]; then
  echo "==== JOB D RESULT tag=$TAG: $ok/$ITERS completed, NO CRASH ===="
fi
