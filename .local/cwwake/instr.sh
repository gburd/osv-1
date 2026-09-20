#!/bin/bash
# Host-side instruments during a cell: iostat -x on the RAW POOL NVMe (/dev/nvme1n1)
# + qemu CPU busy from /proc/<pid>/stat. ARGS: <seconds> <tag>
SEC="${1:-420}"; TAG="${2:-x}"
QPID=$(pgrep -f 'smp 32' | head -1)
echo "QPID=$QPID"
iostat -x 10 $((SEC/10)) /dev/nvme1n1 > /work/iostat-$TAG.txt 2>&1 &
prev=$(awk '{print $14+$15}' /proc/$QPID/stat 2>/dev/null)
for i in $(seq 1 $((SEC/10))); do
  sleep 10
  cur=$(awk '{print $14+$15}' /proc/$QPID/stat 2>/dev/null)
  [ -z "$cur" ] && break
  # utime+stime jiffies delta over 10s -> % of one core; ceiling 3200 for 32 vCPU
  echo "qemu_cpu_pct_of_one_core=$(( (cur-prev)*100/1000 ))  (ceiling 3200 for 32 vCPU)" >> /work/qemucpu-$TAG.txt
  prev=$cur
done
wait
python3 - <<PY > /work/instr-$TAG.summary 2>&1
import statistics as s
rows=[]; hdr=None
for ln in open("/work/iostat-$TAG.txt"):
    f=ln.split()
    if not f: continue
    if f[0]=="Device": hdr=f; continue
    if hdr and f[0].startswith("nvme"):
        d=dict(zip(hdr,f))
        rows.append((float(d.get("%util",0)),float(d.get("w_await",0)),float(d.get("aqu-sz",0)),float(d.get("wkB/s",0)),float(d.get("r/s",0)),float(d.get("w/s",0))))
if rows:
    rows=rows[1:] or rows
    for i,n in enumerate(["%util","w_await","aqu-sz","wkB/s","r/s","w/s"]):
        v=[r[i] for r in rows]
        print(f"nvme1n1 {n}: median={s.median(v):.2f} max={max(v):.2f} n={len(v)}")
PY
cat /work/instr-$TAG.summary
