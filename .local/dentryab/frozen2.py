#!/usr/bin/env python3
"""OSv-side stall localiser via option-3: two pg_stat_activity samples 5s apart.
An ACTIVE backend whose state_change did NOT advance between samples is stalled
below the syscall boundary (OSv not completing its syscall) -- NOT making progress.
Counts stalled vs progressing ACTIVE client backends, plus bg-worker state_change freeze.

Usage: frozen2.py <host> <port> <out.json>   (run on driver, has psql)
"""
import subprocess, sys, time, json, os
host, port, out = sys.argv[1], sys.argv[2], sys.argv[3]
Q = ("select pid, coalesce(backend_type,'?'), coalesce(state,'?'), "
     "coalesce(wait_event_type,'NULL')||':'||coalesce(wait_event,'NULL'), "
     "coalesce(extract(epoch from state_change)::text,'NULL'), "
     "coalesce(extract(epoch from query_start)::text,'NULL') "
     "from pg_stat_activity where pid <> pg_backend_pid()")
def snap():
    r = subprocess.run(["psql","-h",host,"-p",port,"-U","postgres","-d","postgres","-tAF","\t","-c",Q],
                       capture_output=True, text=True, timeout=30,
                       env={**os.environ,"PGCONNECT_TIMEOUT":"20"})
    d={}
    for ln in r.stdout.splitlines():
        f=ln.split("\t")
        if len(f)==6: d[f[0]]={"bt":f[1],"state":f[2],"wait":f[3],"sc":f[4],"qs":f[5]}
    return d, r.returncode
s1,rc1=snap(); t1=time.time()
time.sleep(5)
s2,rc2=snap(); t2=time.time()

active_stalled=[]; active_progress=[]; bgworker_frozen=[]
for pid,a in s1.items():
    b=s2.get(pid)
    if not b: continue
    if a["bt"]=="client backend" and a["state"]=="active" and b["state"]=="active":
        if a["sc"]==b["sc"] and a["sc"]!="NULL":
            active_stalled.append((pid,a["wait"],a["sc"]))
        else:
            active_progress.append((pid,a["wait"]))
    if a["bt"]!="client backend" and a["sc"]==b["sc"]:
        bgworker_frozen.append((pid,a["bt"],a["state"],a["wait"]))
res={
 "rc":[rc1,rc2],"gap_s":round(t2-t1,2),
 "n_backends_s1":len(s1),"n_backends_s2":len(s2),
 "active_client_stalled_count":len(active_stalled),
 "active_client_progressing_count":len(active_progress),
 "active_client_stalled":active_stalled[:40],
 "bgworker_frozen":bgworker_frozen,
 "note":"active+frozen-state_change = stalled below syscall (OSv not completing). "
        "This is the kernel-side view of the wait_event=NULL backends.",
}
open(out,"w").write(json.dumps(res,indent=1))
print(json.dumps({k:res[k] for k in ("active_client_stalled_count","active_client_progressing_count","bgworker_frozen","gap_s")}))
