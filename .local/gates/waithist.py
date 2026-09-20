#!/usr/bin/env python3
"""pg_stat_activity wait-event histogram sampler. Samples every 0.5s for <dur>s
and tallies wait_event_type/wait_event across active backends. The prior null
runs found ~90% wait_event=NULL with device+CPU idle -- this shows whether the
fsync fix shifts the wait profile. ARGS: <host> <dur-s> <out.json>"""
import subprocess, sys, time, json, os
from collections import Counter

host, dur, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
q = ("select coalesce(wait_event_type,'NONE')||'/'||coalesce(wait_event,'NULL') "
     "from pg_stat_activity where state='active' and pid<>pg_backend_pid()")
hist = Counter()
samples = 0
end = time.time() + dur
while time.time() < end:
    r = subprocess.run(["psql","-h",host,"-U","postgres","-d","tpcc","-tAc",q],
                       capture_output=True, text=True, timeout=30,
                       env={**os.environ,"PGCONNECT_TIMEOUT":"15"})
    if r.returncode == 0:
        samples += 1
        for ln in r.stdout.splitlines():
            ln = ln.strip()
            if ln:
                hist[ln] += 1
    time.sleep(0.5)
total = sum(hist.values())
res = {"samples": samples, "active_backend_observations": total,
       "histogram": dict(sorted(hist.items(), key=lambda kv: -kv[1]))}
if total:
    res["pct"] = {k: round(100*v/total,1) for k,v in sorted(hist.items(), key=lambda kv:-kv[1])}
open(out,"w").write(json.dumps(res, indent=1))
print(json.dumps(res))
