#!/usr/bin/env python3
"""Sample pg_stat_activity wait events across the timed window and build a histogram.

Runs on the driver (has psql). Samples every ~2s for <dur> seconds.
Saves raw NDJSON (one line per sample: ts + list of backend rows) AND prints the
aggregated histogram bucketed into LWLock:* / Lock:* / IO:* / Client:* / other / NULL.

CRITICAL semantics (a prior verdict was wrong by 60x on this):
  state='active' with wait_event IS NULL means "running OR runnable, not on a
  registered wait event" -- it is NOT proof of on-CPU. We report the NULL-wait
  count of ACTIVE backends separately and never call it CPU-bound here.

Usage: waitsample.py <host> <port> <dur_s> <raw_out.ndjson> <hist_out.json>
"""
import subprocess, sys, time, json, os
from collections import Counter

host, port, dur = sys.argv[1], sys.argv[2], int(sys.argv[3])
raw_out, hist_out = sys.argv[4], sys.argv[5]
psql = os.environ.get("PSQL", "psql")

# Exclude our own sampling backend and idle-no-txn autovacuum launcher noise is kept
# (we bucket everything). Only count backend_type='client backend' work + others separately.
QUERY = (
    "select coalesce(backend_type,'?'), coalesce(state,'?'), "
    "coalesce(wait_event_type,'NULL'), coalesce(wait_event,'NULL') "
    "from pg_stat_activity where pid <> pg_backend_pid()"
)

samples = []
end = time.time() + dur
rawf = open(raw_out, "w")
n_samples = 0
while time.time() < end:
    t0 = time.time()
    r = subprocess.run([psql, "-h", host, "-p", port, "-U", "postgres", "-d", "postgres",
                        "-tAF", "\t", "-c", QUERY],
                       capture_output=True, text=True, timeout=30,
                       env={**os.environ, "PGCONNECT_TIMEOUT": "20"})
    ts = time.time()
    rows = []
    if r.returncode == 0:
        for ln in r.stdout.splitlines():
            f = ln.split("\t")
            if len(f) == 4:
                rows.append(f)  # backend_type, state, wet, we
        samples.append(rows)
        n_samples += 1
    rawf.write(json.dumps({"ts": ts, "rc": r.returncode, "rows": rows}) + "\n")
    rawf.flush()
    sl = 2.0 - (time.time() - t0)
    if sl > 0:
        time.sleep(sl)
rawf.close()

# Aggregate. Count backend-observations (sum over all samples of matching rows).
def bucket(wet, we):
    if wet == "NULL":
        return "NULL(no-wait-event)"
    return f"{wet}:{we}"

# Only client backends doing work matter for the discriminator, but keep all.
hist = Counter()               # bucket -> observation count (client backends only)
hist_all = Counter()           # bucket -> observation count (all backend types)
by_type = Counter()            # wait_event_type -> count (client backends)
active_null = 0                # client backends state=active AND wait_event NULL
active_total = 0
idle_total = 0
for rows in samples:
    for bt, st, wet, we in rows:
        b = bucket(wet, we)
        hist_all[b] += 1
        if bt == "client backend":
            hist[b] += 1
            by_type[wet if wet != "NULL" else "NULL"] += 1
            if st == "active":
                active_total += 1
                if wet == "NULL":
                    active_null += 1
            elif st.startswith("idle"):
                idle_total += 1

def top(counter, k=25):
    return counter.most_common(k)

# coarse buckets
coarse = Counter()
for b, c in hist.items():
    if b.startswith("LWLock:"): coarse["LWLock:*"] += c
    elif b.startswith("Lock:"): coarse["Lock:*"] += c
    elif b.startswith("IO:"):   coarse["IO:*"] += c
    elif b.startswith("Client:"): coarse["Client:*"] += c
    elif b == "NULL(no-wait-event)": coarse["NULL(no-wait-event)"] += c
    else: coarse["other"] += c

out = {
    "n_samples": n_samples,
    "dur_requested_s": dur,
    "client_backend": {
        "coarse_buckets": dict(coarse.most_common()),
        "by_wait_event_type": dict(by_type.most_common()),
        "top_wait_events": top(hist, 30),
        "active_total_obs": active_total,
        "active_with_NULL_wait_event_obs": active_null,
        "idle_total_obs": idle_total,
        "note": "active+NULL means not-on-a-registered-wait-event, NOT proof of on-CPU",
    },
    "all_backends_top": top(hist_all, 30),
}
open(hist_out, "w").write(json.dumps(out, indent=1))
print(json.dumps(out["client_backend"]["coarse_buckets"]))
print("active_total_obs", active_total, "active_NULL_wait_obs", active_null, "samples", n_samples)
