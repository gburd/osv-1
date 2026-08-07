#!/bin/bash
# DROP DATABASE loop against OSv PG on 127.0.0.1:5432. Runs N iters.
# Prints per-iter result; counts ok/fail. Crash = PG gone (connection refused).
set -u
N="${1:-30}"
PSQL="psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -v ON_ERROR_STOP=1 -tA"
export PGCONNECT_TIMEOUT=8
ok=0
for i in $(seq 1 "$N"); do
  if timeout 40 $PSQL -c "CREATE DATABASE x TEMPLATE template0;" >/tmp/it.log 2>&1 \
     && timeout 40 $PSQL -c "DROP DATABASE x;" >>/tmp/it.log 2>&1; then
    ok=$((ok+1)); echo "iter $i: CREATE+DROP OK (ok=$ok)"
  else
    echo "iter $i: FAILED"; cat /tmp/it.log | tail -5
    # check if PG still alive
    if ! timeout 8 $PSQL -c "SELECT 1;" >/dev/null 2>&1; then
      echo "iter $i: PG DEAD (crash) -- aborting"; echo "==== DROP DATABASE RESULT: $ok/$N (CRASH at iter $i) ===="; exit 1
    fi
  fi
done
echo "==== DROP DATABASE RESULT: $ok/$N completed ===="
