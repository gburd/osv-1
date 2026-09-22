#!/bin/bash
# CPU PER TRANSACTION, per arm -- THE HEADLINE.
#
# Prior run: OSv 180.1 us/txn vs Linux 86.2 us/txn = 2.09x.  The question this run
# exists to answer is whether the ALIGNED base moved it (it now contains
# ae077860c, a lock-contention fix on the virtio-blk completion path).
#
# METHOD, and why it is not a ratio-of-ratios artifact: CPU/txn is an ABSOLUTE
# per-arm quantity = (busy vCPU during the window) / (tps during the window).
# Both terms are measured over the SAME window on the SAME arm, so no
# cross-arm normalisation enters, and the per-unit-ratio trap that fabricated a
# 4.8x write amplification does not apply.
#
# WINDOWED DELTAS ON BOTH ARMS -- this is the part a cumulative snapshot gets
# wrong.  /proc/stat is monotonic since boot, so a single read during load
# measures the whole uptime, not the load.  Both arms therefore sample at the
# START and END of the measured window and difference:
#   OSv   : SCHEDPROBE agg_busy_vcpu, already a per-10s windowed delta from
#           cpu->idle_thread->thread_clock() (kernel accounting, not an estimate).
#   Linux : /proc/stat aggregate delta across the window, busy = total - idle - iowait.
# One long run per arm (not 3x60s) so the window is long enough that checkpoint /
# autovacuum backlog is amortised rather than sampled at a random phase.
#
# ARGS: <arm: osv|lin> <vu> <mode: ro|rw> <secs>
set -u
. /home/gburd/ws/osv/.local/bench24/env.sh
ARM=$1; VU=$2; MODE=$3; T=$4
PGB=/usr/lib/postgresql/18/bin
FLAG=""; [ "$MODE" = ro ] && FLAG="-S"
J=$VU; [ "$J" -gt 32 ] && J=32
H=$([ "$ARM" = osv ] && echo "$OSVPRIV" || echo "$LINUXPRIV")
OUT="$NB/raw/cputxn-$ARM-$MODE-vu$VU"

if [ "$ARM" = lin ]; then
  ssh $SSHO $LINUX "head -1 /proc/stat" > "$OUT.stat0"
fi
# start the load, remember when
date -u +%s > "$OUT.t0"
ssh $SSHO $DRV "$PGB/pgbench $FLAG -h $H -U postgres -d postgres -c $VU -j $J -T $T -P 10" \
  > "$OUT.pgbench" 2> "$OUT.pgbench.err"
date -u +%s > "$OUT.t1"
if [ "$ARM" = lin ]; then
  ssh $SSHO $LINUX "head -1 /proc/stat" > "$OUT.stat1"
fi

TPS=$(awk '/^tps =/{print $3; exit}' "$OUT.pgbench")
FAILED=$(awk '/number of failed transactions/{print $5; exit}' "$OUT.pgbench" | tr -cd '0-9')

if [ "$ARM" = osv ]; then
  # Take the SCHEDPROBE samples from the loaded window only.  Console is
  # cumulative text, so use the last N samples, where N covers the window; each
  # is an independent 10s delta, so the median is a robust steady-state estimate.
  aws ec2 get-console-output --region $REGION --instance-id $OSVID --latest --output text 2>/dev/null \
    | grep "SCHEDPROBE ncpu" | tail -$(( T / 10 )) > "$OUT.sched"
  BUSY=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^agg_busy_vcpu=/){split($i,a,"=");print a[2]}}' "$OUT.sched" \
          | sort -n | awk '{v[NR]=$1} END{print (NR%2)?v[(NR+1)/2]:(v[NR/2]+v[NR/2+1])/2}')
  NLE5=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^n_le5=/){split($i,a,"=");print a[2]}}' "$OUT.sched" | sort -n | tail -1)
  echo "OSV_SCHED_SAMPLES=$(wc -l < "$OUT.sched") n_le5_max=$NLE5"
else
  BUSY=$(python3 -c "
a=[int(x) for x in open('$OUT.stat0').read().split()[1:]]
b=[int(x) for x in open('$OUT.stat1').read().split()[1:]]
d=[y-x for x,y in zip(a,b)]; tot=sum(d); busy=tot-d[3]-d[4]
print(f'{32.0*busy/tot:.2f}')")
fi

python3 -c "
tps=float('$TPS'); busy=float('$BUSY')
print(f'CPUTXN arm=$ARM mode=$MODE vu=$VU tps={tps:.0f} busy_vcpu={busy:.2f} of 32 "\
"cpu_us_per_txn={1e6*busy/tps:.1f} failed=${FAILED:-0}')
# Little's law check: in a CLOSED loop latency is forced to be clients/throughput,
# so a latency is NOT independent evidence of a wait.  Print N=X*R so the reader
# can see whether it recovers the client count before treating latency as data.
"
LAT=$(awk '/^latency average/{print $4; exit}' "$OUT.pgbench")
python3 -c "
tps=float('$TPS'); lat=float('$LAT'); vu=$VU
n=tps*lat/1000.0
print(f'LITTLE arm=$ARM vu=$VU lat_ms={lat} predicted_lat_ms={1000.0*vu/tps:.3f} N=X*R={n:.1f} of {vu} clients -> {\"RECOVERS: latency carries no information beyond throughput\" if abs(n-vu)/vu<0.05 else \"does NOT recover\"}')"
