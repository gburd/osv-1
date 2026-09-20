#!/bin/bash
# DRIVER-side instruments during a cell. The confound this closes: HammerDB runs one
# thread per VU, so at VU192 the driver is 192 client threads; if the DRIVER saturates
# (CPU or NIC) both arms flatten and the OSv/Linux ratio falsely converges to 1.0.
# So the driver must be MEASURED every cell, not assumed adequate.
# Records: all-CPU busy%, load average, HammerDB-process CPU, NIC Mbps/pps.
# ARGS: <seconds> <tag>
SEC="${1:-420}"; TAG="${2:-x}"
NCPU=$(nproc)
NIC=$(ip -4 -o addr show scope global | awk '{print $2}' | head -1)
echo "DRVINSTR tag=$TAG ncpu=$NCPU nic=$NIC"
: > /tmp/drvcpu-$TAG.txt
prev_all=$(awk '/^cpu /{print $2+$3+$4+$6+$7+$8, $2+$3+$4+$5+$6+$7+$8}' /proc/stat)
prev_busy=${prev_all% *}; prev_tot=${prev_all#* }
prx=$(cat /sys/class/net/$NIC/statistics/rx_bytes 2>/dev/null || echo 0)
ptx=$(cat /sys/class/net/$NIC/statistics/tx_bytes 2>/dev/null || echo 0)
prp=$(cat /sys/class/net/$NIC/statistics/rx_packets 2>/dev/null || echo 0)
ptp=$(cat /sys/class/net/$NIC/statistics/tx_packets 2>/dev/null || echo 0)
for i in $(seq 1 $((SEC/10))); do
  sleep 10
  cur=$(awk '/^cpu /{print $2+$3+$4+$6+$7+$8, $2+$3+$4+$5+$6+$7+$8}' /proc/stat)
  cb=${cur% *}; ct=${cur#* }
  db=$((cb-prev_busy)); dt=$((ct-prev_tot))
  [ "$dt" -le 0 ] && dt=1
  ALLPCT=$((db*100/dt))
  prev_busy=$cb; prev_tot=$ct
  # HammerDB process tree CPU (all hammerdbcli/tclsh threads), % of ONE core summed
  HPCT=$(ps -eo pcpu,comm,args --no-headers 2>/dev/null | grep -iE 'hammerdb|tclsh8|vuser' | awk '{s+=$1} END{printf "%.0f", s}')
  LOAD=$(cut -d' ' -f1-3 /proc/loadavg)
  crx=$(cat /sys/class/net/$NIC/statistics/rx_bytes 2>/dev/null || echo 0)
  ctx=$(cat /sys/class/net/$NIC/statistics/tx_bytes 2>/dev/null || echo 0)
  crp=$(cat /sys/class/net/$NIC/statistics/rx_packets 2>/dev/null || echo 0)
  ctp=$(cat /sys/class/net/$NIC/statistics/tx_packets 2>/dev/null || echo 0)
  echo "drv_all_cpu_pct=$ALLPCT hdb_cpu_pct_of_one_core=${HPCT:-0} ncpu=$NCPU load=\"$LOAD\" rx_Mbps=$(( (crx-prx)*8/10/1000000 )) tx_Mbps=$(( (ctx-ptx)*8/10/1000000 )) rx_pps=$(( (crp-prp)/10 )) tx_pps=$(( (ctp-ptp)/10 ))" >> /tmp/drvcpu-$TAG.txt
  prx=$crx; ptx=$ctx; prp=$crp; ptp=$ctp
done
python3 /tmp/drvdisc.py $TAG > /tmp/drvinstr-$TAG.summary 2>&1
cat /tmp/drvinstr-$TAG.summary
