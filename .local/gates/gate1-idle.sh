#!/bin/bash
# GATE 1 - idle-regression A/B on the METAL (clean host CPU counter, not a guest guess).
# Measures the qemu process host CPU (utime+stime jiffies from /proc/<pid>/stat) consumed by a
# MOSTLY-IDLE OSv guest over a fixed window, adaptive-v2 (ADAPT=1) vs fixed-10000 (ADAPT=0).
# The guest has PG up + a few idle connections holding long think-time (quiescent). PASS =
# adaptive idle host-CPU <= fixed idle host-CPU + small margin. If adaptive burns materially
# more -> that is the honest idle cost (fix stays opt-in, not default).
#
# ARGS: <adapt: 1|0>   (0 => fixed@10000, the historical baseline)
# Runs from the workstation. Writes /work/gate1-<arm>.txt on the metal AND echoes the number.
set -uo pipefail
. /home/gburd/ws/osv/.local/gates/env.sh
ADAPT="${1:-1}"
ARM="adaptive"; [ "$ADAPT" = 0 ] && ARM="fixed10000"
PGH=$METALPRIV
WINDOW="${WINDOW:-120}"      # measurement window seconds
NCONN="${NCONN:-4}"          # a few idle connections (mostly-idle server)

echo "=== GATE1 [$ARM] : kill prior guest, ensure lock free ==="
timeout 20 ssh $SSHO $METAL "sudo setsid --fork sh -c 'pkill -9 -f \"qemu-system-x86_64 -M pc\"' </dev/null >/dev/null 2>&1; echo KILL_SENT" 2>&1 || true
for k in $(seq 1 15); do
  sleep 3
  R=$(timeout 20 ssh $SSHO $METAL "if sudo fuser /work/osv/build/last/usr.img >/dev/null 2>&1; then echo LOCKED; else echo FREE; fi" 2>&1)
  [ "$R" = FREE ] && { echo LOCKCHK_DONE; break; }
done

echo "=== GATE1 [$ARM] : fresh boot (ADAPT=$ADAPT FIXEDSPIN=10000) ==="
timeout 20 ssh $SSHO $METAL "sudo ADAPT=$ADAPT FIXEDSPIN=10000 setsid --fork bash /tmp/boot-osv.sh run </dev/null >/dev/null 2>&1; echo BOOTED" 2>&1

echo "=== GATE1 [$ARM] : wait for PG ==="
up=0
for i in $(seq 1 90); do
  R=$(timeout 15 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=8 psql -h $PGH -U postgres -d tpcc -tAc 'select 1' 2>&1" 2>&1)
  echo "$R" | grep -q '^1$' && { echo "PG up ($i)"; up=1; break; }
  sleep 6
done
[ "$up" = 1 ] || { echo "GATE1 [$ARM]: PG NEVER UP"; timeout 20 ssh $SSHO $METAL "sudo tail -25 /work/console-run.log"; exit 2; }

echo "=== GATE1 [$ARM] : confirm spin lever from console ==="
timeout 20 ssh $SSHO $METAL "sudo grep -m1 SPINLEVER /work/console-run.log" 2>&1

echo "=== GATE1 [$ARM] : quiesce (2 sub-1s checkpoints) then settle ==="
timeout 200 ssh $SSHO $DRV "bash /tmp/quiesce.sh $PGH 2>&1 | tail -4" 2>&1
sleep 5

echo "=== GATE1 [$ARM] : open $NCONN idle connections (mostly-idle, long think-time) ==="
# hold NCONN psql sessions idle-in-transaction-free, each just sleeps; a request/reply server
# with a handful of quiescent workers is exactly the mostly-idle case the gate must probe.
timeout 20 ssh $SSHO $DRV "for c in \$(seq 1 $NCONN); do setsid --fork sh -c 'PGCONNECT_TIMEOUT=8 psql -h $PGH -U postgres -d tpcc -c \"select pg_sleep($((WINDOW+40)))\" >/dev/null 2>&1' </dev/null >/dev/null 2>&1; done; echo IDLE_CONNS_OPEN" 2>&1
sleep 3

echo "=== GATE1 [$ARM] : measure qemu host CPU over ${WINDOW}s (utime+stime jiffies) ==="
timeout $((WINDOW+60)) ssh $SSHO $METAL "
QPID=\$(pgrep -f 'smp 32' | head -1)
echo QPID=\$QPID
CLK=\$(getconf CLK_TCK)
echo CLK_TCK=\$CLK
read a0 b0 <<<\"\$(awk '{print \$14, \$15}' /proc/\$QPID/stat)\"
UP0=\$(awk '{print \$1}' /proc/uptime)
sleep $WINDOW
read a1 b1 <<<\"\$(awk '{print \$14, \$15}' /proc/\$QPID/stat)\"
UP1=\$(awk '{print \$1}' /proc/uptime)
DJ=\$(( (a1+b1) - (a0+b0) ))
WALL=\$(awk -v x=\$UP1 -v y=\$UP0 'BEGIN{printf \"%.2f\", x-y}')
# jiffies -> seconds of one core; % of one core = 100 * cpu_sec / wall
CPUSEC=\$(awk -v dj=\$DJ -v clk=\$CLK 'BEGIN{printf \"%.3f\", dj/clk}')
PCT1=\$(awk -v cs=\$CPUSEC -v w=\$WALL 'BEGIN{printf \"%.2f\", 100*cs/w}')
echo \"GATE1_RESULT arm=$ARM window_s=\$WALL delta_jiffies=\$DJ cpu_core_seconds=\$CPUSEC pct_of_one_core=\$PCT1\"
echo \"GATE1_RESULT arm=$ARM window_s=\$WALL delta_jiffies=\$DJ cpu_core_seconds=\$CPUSEC pct_of_one_core=\$PCT1\" > /work/gate1-$ARM.txt
" 2>&1 | tee /home/gburd/ws/osv/.local/gates/cells/gate1-$ARM.txt

echo "=== GATE1 [$ARM] : clean poweroff (never kill mid-checkpoint) ==="
timeout 120 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=15 psql -h $PGH -U postgres -d tpcc -c 'CHECKPOINT' 2>&1 | tail -1" 2>&1
timeout 60 ssh $SSHO $DRV "PGCONNECT_TIMEOUT=15 psql -h $PGH -U postgres -d tpcc -c 'CHECKPOINT' 2>&1 | tail -1" 2>&1
sleep 3
# detach kill (killing qemu drops this ssh on this metal); poll qemu-count separately
timeout 20 ssh $SSHO $METAL "sudo setsid --fork sh -c 'pkill -9 -f \"qemu-system-x86_64 -M pc\"' </dev/null >/dev/null 2>&1; echo KILL_SENT" 2>&1 || true
for k in $(seq 1 12); do
  sleep 4
  R=$(timeout 20 ssh $SSHO $METAL "ps -eo cmd | grep -c '[q]emu-system-x86_64 -M pc'" 2>/dev/null | tr -d '[:space:]')
  [ "$R" = 0 ] && { echo GUEST_DOWN; break; }
done
echo "=== GATE1 [$ARM] DONE ==="
