#!/bin/bash
# LEAK #2 FIX data-integrity + memory churn. Each round forks N backends; each
# backend builds an ~8KB unique payload on its heap, stores it, reads it back and
# verifies md5 server-side, and checks its own row prefix (no other backend's
# data bled through). A cross-AS VA/heap aliasing bug corrupts the payload -> the
# DO block RAISEs -> psql exits non-zero -> counted as CORRUPT. Reports per-round
# ok/fail/corrupt + the LEAKPROBE line so mem_free/fb_bytes/arena line up.
set -u
ROUNDS="${1:-300}"; N="${2:-32}"; H="${3:-192.168.100.2}"
export PGCONNECT_TIMEOUT=10
CONSOLE=$(ls -t /work/console-run-*.log | head -1)
LOG=/work/integ-$(date +%H%M%S).log
echo "INTEGRITY rounds=$ROUNDS N=$N console=$CONSOLE" | tee "$LOG"

psql -h "$H" -U postgres -d demo -qtAc \
  "CREATE TABLE IF NOT EXISTS churn_integ(id text primary key, payload text, md5 text);" >/dev/null 2>&1

# Per-connection SQL as a here-doc written to a file, parameterized by env vars
# the DO block reads via current_setting (avoids all shell-quoting hazards).
SQLF=/work/integ_conn.sql
cat > "$SQLF" <<'SQL'
DO $$
DECLARE
  myid text := current_setting('churn.rc') || pg_backend_pid();
  pay  text := repeat(myid || '|', 400);
  got  text; gotmd text;
BEGIN
  INSERT INTO churn_integ(id,payload,md5) VALUES (myid, pay, md5(pay))
    ON CONFLICT (id) DO UPDATE SET payload=EXCLUDED.payload, md5=EXCLUDED.md5;
  SELECT payload, md5 INTO got, gotmd FROM churn_integ WHERE id = myid;
  IF got IS NULL THEN RAISE EXCEPTION 'INTEG_MISSING %', myid; END IF;
  IF md5(got) <> md5(pay) OR gotmd <> md5(pay) THEN
    RAISE EXCEPTION 'INTEG_CORRUPT id=% expect=% got=% stored=%', myid, md5(pay), md5(got), gotmd;
  END IF;
  IF left(got, length(myid)) <> myid THEN
    RAISE EXCEPTION 'INTEG_BLEED id=% prefix=%', myid, left(got, length(myid));
  END IF;
END $$;
SQL

one_conn() {
  PGOPTIONS="-c churn.rc=r${1}c${2}p" \
    psql -h "$H" -U postgres -d demo -v ON_ERROR_STOP=1 -qtAX -f "$SQLF" >/dev/null 2>>"$3"
  echo "$?" >>"$4"
}

t0=$(date +%s); totcorrupt=0
for r in $(seq 1 "$ROUNDS"); do
  err=$(mktemp); rc=$(mktemp); pids=""
  for c in $(seq 1 "$N"); do
    one_conn "$r" "$c" "$err" "$rc" &
    pids="$pids $!"
  done
  for p in $pids; do wait "$p"; done
  ok=$(grep -c '^0$' "$rc"); ok=${ok:-0}
  fail=$(grep -cv '^0$' "$rc"); fail=${fail:-0}
  corrupt=$(grep -c 'INTEG_' "$err"); corrupt=${corrupt:-0}
  totcorrupt=$((totcorrupt + corrupt))
  if [ "$corrupt" -ne 0 ]; then head -3 "$err" | tee -a "$LOG"; fi
  rm -f "$err" "$rc"
  if [ $((r % 10)) -eq 0 ] || [ "$corrupt" -ne 0 ]; then
    probe=$(grep '^LEAKPROBE ' "$CONSOLE" 2>/dev/null | tail -1)
    printf "ROUND %d elapsed=%ds ok=%d fail=%d CORRUPT=%d totCORRUPT=%d | %s\n" \
      "$r" "$(( $(date +%s) - t0 ))" "$ok" "$fail" "$corrupt" "$totcorrupt" "$probe" | tee -a "$LOG"
  fi
done
echo "INTEGRITY done totalCORRUPT=$totcorrupt" | tee -a "$LOG"
