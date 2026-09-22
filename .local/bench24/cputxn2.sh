#!/bin/bash
# CPU/txn, SECOND INDEPENDENT METHOD for the Linux arm.
#
# WHY THIS EXISTS: the first Linux measurement bracketed /proc/stat around the
# whole pgbench invocation (via two ssh round trips) and reported 31.37 of 32
# vCPU = 98% busy.  CloudWatch over the same load reported ~86%.  A ~12-point
# disagreement lands directly on the headline, and the rule is that when two
# measurements disagree you find out WHY rather than preferring one.
#
# Two candidate causes, and they are distinguishable:
#   (a) BOUNDARY DILUTION/INFLATION -- the bracket includes ssh latency, pgbench
#       connection setup and the client ramp, so it is not the steady-state window.
#   (b) CLOUDWATCH AVERAGING -- its 5-minute period straddles idle time before and
#       after the run, which would make CloudWatch read LOW, not the delta read high.
# This sampler removes (a): it samples /proc/stat ON THE BOX over a tight window
# fully INSIDE a longer load, with no ssh in the measured interval, matching how
# the OSv arm is measured (SCHEDPROBE's own 10 s in-kernel deltas, median over
# steady-state samples only).  That makes the two arms methodologically parallel,
# which is the property the comparison actually needs.
# ARGS: <arm> <vu> <mode> <total_secs> <sample_secs>
set -u
. /home/gburd/ws/osv/.local/bench24/env.sh
ARM=$1; VU=$2; MODE=$3; T=$4; W=$5
PGB=/usr/lib/postgresql/18/bin
FLAG=""; [ "$MODE" = ro ] && FLAG="-S"
J=$VU; [ "$J" -gt 32 ] && J=32
H=$([ "$ARM" = osv ] && echo "$OSVPRIV" || echo "$LINUXPRIV")
OUT="$NB/raw/cputxn2-$ARM-$MODE-vu$VU"
TARGET=$([ "$ARM" = osv ] && echo "$OSVID" || echo "$LINUX")

# start the load in the background on the driver
ssh $SSHO $DRV "nohup $PGB/pgbench $FLAG -h $H -U postgres -d postgres -c $VU -j $J -T $T -P 10 \
   > /tmp/cputxn2.out 2>/tmp/cputxn2.err & echo LOAD_STARTED" >/dev/null 2>&1
sleep 45   # let the ramp settle well inside the window

if [ "$ARM" = lin ]; then
  # Sample ENTIRELY on the box: one ssh, the timing loop runs remotely, so no
  # network latency is inside the measured interval.  Per-CPU too, so the Linux
  # arm gets the same distribution evidence the OSv arm gets -- an aggregate
  # cannot distinguish "all busy" from "some idle" on either arm.
  ssh $SSHO $LINUX "bash -s" > "$OUT.sample" <<EOS
a=\$(grep '^cpu' /proc/stat)
sleep $W
b=\$(grep '^cpu' /proc/stat)
printf '%s\n---\n%s\n' "\$a" "\$b"
EOS
  python3 - "$OUT.sample" "$W" > "$OUT.calc" <<'PY'
import sys
txt=open(sys.argv[1]).read().split('---')
A=[l.split() for l in txt[0].strip().splitlines()]
B=[l.split() for l in txt[1].strip().splitlines()]
def busy(a,b):
    a=[int(x) for x in a[1:]]; b=[int(x) for x in b[1:]]
    d=[y-x for x,y in zip(a,b)]; tot=sum(d)
    return (tot-d[3]-d[4])/tot if tot else 0.0
agg=busy(A[0],B[0])
per=[busy(A[i],B[i]) for i in range(1,len(A))]
n=len(per)
print(f"LIN_AGG_BUSY_VCPU={agg*n:.2f} of {n}")
print("LIN_PERCPU_BUSY_PCT="+",".join(f"{int(round(p*100))}" for p in per))
print(f"LIN_n_ge50={sum(1 for p in per if p>=0.50)} LIN_n_le5={sum(1 for p in per if p<=0.05)}")
PY
  cat "$OUT.calc"
fi
wait
ssh $SSHO $DRV "cat /tmp/cputxn2.out" > "$OUT.pgbench" 2>/dev/null
ssh $SSHO $DRV "cat /tmp/cputxn2.err" > "$OUT.pgbench.err" 2>/dev/null
# Steady-state tps from the -P interval samples INSIDE the measured window, not
# the whole-run average (which includes the ramp the CPU sample excludes).
awk '/^progress:/{for(i=1;i<=NF;i++) if($i=="tps,") print $(i-1)}' "$OUT.pgbench.err" > "$OUT.itps"
python3 -c "
import statistics as s
v=[float(x) for x in open('$OUT.itps') if x.strip()]
mid=v[3:] if len(v)>6 else v
print(f'STEADY_TPS_median={s.median(mid):.0f} (from {len(mid)} interval samples, ramp excluded)')
print(f'WHOLE_RUN_tps=' + open('$OUT.pgbench').read().split('tps = ')[1].split(' ')[0] if 'tps = ' in open('$OUT.pgbench').read() else '')
"
grep -E "number of failed" "$OUT.pgbench"
