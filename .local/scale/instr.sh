#!/bin/bash
# HOST-side instruments during a cell: iostat -x on the RAW POOL NVMe (/dev/nvme1n1)
# + qemu CPU busy from /proc/<pid>/stat + host-side tap0 packet/byte rate.
# ARGS: <seconds> <tag>
SEC="${1:-420}"; TAG="${2:-x}"; DEV="${3:-nvme1n1}"
QPID=$(pgrep -f 'qemu-system-x86_64 -M pc' | head -1)
echo "QPID=$QPID"
iostat -x 10 $((SEC/10)) /dev/$DEV > /work/iostat-$TAG.txt 2>&1 &
prev=$(awk '{print $14+$15}' /proc/$QPID/stat 2>/dev/null)
# tap0 counters: the guest<->driver path. rx/tx from the HOST's view of tap0.
tprev_rx=$(cat /sys/class/net/tap0/statistics/rx_bytes 2>/dev/null || echo 0)
tprev_tx=$(cat /sys/class/net/tap0/statistics/tx_bytes 2>/dev/null || echo 0)
tprev_rp=$(cat /sys/class/net/tap0/statistics/rx_packets 2>/dev/null || echo 0)
tprev_tp=$(cat /sys/class/net/tap0/statistics/tx_packets 2>/dev/null || echo 0)
: > /work/tap-$TAG.txt
for i in $(seq 1 $((SEC/10))); do
  sleep 10
  cur=$(awk '{print $14+$15}' /proc/$QPID/stat 2>/dev/null)
  [ -z "$cur" ] && break
  # utime+stime jiffies delta over 10s -> % of one core; ceiling 3200 for 32 vCPU
  echo "qemu_cpu_pct_of_one_core=$(( (cur-prev)*100/1000 ))  (ceiling 3200 for 32 vCPU)" >> /work/qemucpu-$TAG.txt
  prev=$cur
  trx=$(cat /sys/class/net/tap0/statistics/rx_bytes 2>/dev/null || echo 0)
  ttx=$(cat /sys/class/net/tap0/statistics/tx_bytes 2>/dev/null || echo 0)
  trp=$(cat /sys/class/net/tap0/statistics/rx_packets 2>/dev/null || echo 0)
  ttp=$(cat /sys/class/net/tap0/statistics/tx_packets 2>/dev/null || echo 0)
  echo "tap0 rx_Mbps=$(( (trx-tprev_rx)*8/10/1000000 )) tx_Mbps=$(( (ttx-tprev_tx)*8/10/1000000 )) rx_pps=$(( (trp-tprev_rp)/10 )) tx_pps=$(( (ttp-tprev_tp)/10 ))" >> /work/tap-$TAG.txt
  tprev_rx=$trx; tprev_tx=$ttx; tprev_rp=$trp; tprev_tp=$ttp
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
# tap0 network: is the guest<->driver link anywhere near line rate?
try:
    tv=[dict(kv.split('=') for kv in ln.split()[1:]) for ln in open("/work/tap-$TAG.txt") if ln.startswith("tap0")]
    for k in ["rx_Mbps","tx_Mbps","rx_pps","tx_pps"]:
        v=[int(d[k]) for d in tv if k in d]
        if v: print(f"tap0 {k}: median={s.median(v):.0f} max={max(v)} n={len(v)}")
except Exception as e:
    print("tap parse:", e)
PY
cat /work/instr-$TAG.summary
