#!/bin/bash
# Host-side instruments during a run: iostat -x %util + qemu CPU from /proc/<pid>/stat.
# ARGS: <seconds> <tag>
SEC="${1:-120}"; TAG="${2:-x}"
QPID=$(pgrep -f 'qemu-system' | head -1)
echo "QPID=$QPID"
iostat -x 10 $((SEC/10)) /dev/nvme0n1 > /work/iostat-$TAG.txt 2>&1 &
# qemu CPU: utime+stime jiffies delta -> % of one core; /32 vCPU ceiling = 3200%
prev=$(awk '{print $14+$15}' /proc/$QPID/stat 2>/dev/null)
for i in $(seq 1 $((SEC/10))); do
  sleep 10
  cur=$(awk '{print $14+$15}' /proc/$QPID/stat 2>/dev/null)
  [ -z "$cur" ] && break
  echo "qemu_cpu_pct_of_one_core=$(( (cur-prev)*100/1000 ))  (ceiling 3200 for 32 vCPU)" >> /work/qemucpu-$TAG.txt
  prev=$cur
done
wait
echo "=== iostat %util (col by header) ==="
python3 - <<PY
import re
rows=[]
hdr=None
for ln in open("/work/iostat-$TAG.txt"):
    f=ln.split()
    if not f: continue
    if f[0]=="Device": hdr=f; continue
    if hdr and f[0].startswith("nvme"):
        d=dict(zip(hdr,f))
        rows.append((float(d.get("%util",0)),float(d.get("w_await",0)),float(d.get("aqu-sz",0)),float(d.get("wkB/s",0))))
if rows:
    rows=rows[1:] or rows   # drop the since-boot summary line
    import statistics as s
    for i,n in enumerate(["%util","w_await","aqu-sz","wkB/s"]):
        v=[r[i] for r in rows]
        print(f"{n}: median={s.median(v):.2f} min={min(v):.2f} max={max(v):.2f} n={len(v)}")
PY
cat /work/qemucpu-$TAG.txt 2>/dev/null | tail -5
