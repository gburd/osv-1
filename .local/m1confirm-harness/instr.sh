#!/bin/bash
# Host-side instruments during a run: iostat -x %util + qemu CPU from /proc/<pid>/stat.
# Plus PER-vCPU-THREAD busy spread: how many of qemu's vCPU threads accumulate
# jiffies over the window. This is the #1509 validity signal -- SINGLE funnels the
# zio_interrupt/cv_broadcast completion work onto few vCPUs; PERQ should spread it
# across more (a per-queue completion thread runs on the CPU that owns that queue).
# ARGS: <seconds> <tag>
SEC="${1:-120}"; TAG="${2:-x}"
QPID=$(pgrep -f 'qemu-system' | head -1)
echo "QPID=$QPID"
iostat -x 10 $((SEC/10)) /dev/nvme0n1 > /work/iostat-$TAG.txt 2>&1 &
# snapshot per-task jiffies at start and end -> count busy vCPU threads
declare -A t0
for s in /proc/$QPID/task/*/stat; do tid=$(basename $(dirname $s)); j=$(awk '{print $14+$15}' $s 2>/dev/null); t0[$tid]=${j:-0}; done
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
# per-vCPU busy spread: count threads whose jiffies grew, and by how much
{
  echo "=== per-vCPU-thread busy spread over window ($TAG) ==="
  busy=0; total_j=0
  for s in /proc/$QPID/task/*/stat; do
    [ -e "$s" ] || continue
    tid=$(basename $(dirname $s))
    name=$(awk '{print $2}' $s 2>/dev/null)
    j=$(awk '{print $14+$15}' $s 2>/dev/null); j=${j:-0}
    d=$(( j - ${t0[$tid]:-0} ))
    if [ "$d" -gt 20 ]; then busy=$((busy+1)); total_j=$((total_j+d)); echo "  vcpu_thr $name tid=$tid busy_jiffies=$d"; fi
  done
  echo "vCPU_threads_busy(>200ms cpu)=$busy  total_busy_jiffies=$total_j"
} >> /work/vcpuspread-$TAG.txt 2>&1
cat /work/vcpuspread-$TAG.txt
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
