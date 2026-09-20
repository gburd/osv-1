#!/usr/bin/env python3
"""Fresh-connect probe: connect, select 1, close -- once per second.
Runs ALONE during the timed window. Reports n/median/p95/p99/max and >=1s/5s/10s counts."""
import subprocess, sys, time, statistics, json, os

host, port, dur, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
psql = os.environ.get("PSQL", "psql")
lat, errs = [], 0
end = time.time() + dur
while time.time() < end:
    t0 = time.time()
    r = subprocess.run([psql, "-h", host, "-p", port, "-U", "postgres", "-d", "postgres",
                        "-tAc", "select 1", "-v", "ON_ERROR_STOP=1"],
                       capture_output=True, text=True, timeout=120,
                       env={**os.environ, "PGCONNECT_TIMEOUT": "60"})
    el = time.time() - t0
    if r.returncode == 0 and r.stdout.strip() == "1":
        lat.append(el)
    else:
        errs += 1
    sl = 1.0 - (time.time() - t0)
    if sl > 0:
        time.sleep(sl)

def q(v, p):
    if not v: return None
    s = sorted(v); i = min(int(round(p * (len(s) - 1))), len(s) - 1)
    return s[i]

res = dict(n=len(lat), errors=errs,
           median=q(lat, .5), p95=q(lat, .95), p99=q(lat, .99), max=max(lat) if lat else None,
           ge1s=sum(1 for x in lat if x >= 1), ge5s=sum(1 for x in lat if x >= 5),
           ge10s=sum(1 for x in lat if x >= 10))
open(out, "w").write(json.dumps(res, indent=1))
print(json.dumps(res))
