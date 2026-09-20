#!/bin/bash
# THE SWEEP DRIVER. Runs cells sequentially, INTERLEAVING the two arms at each VU.
#
# WHY INTERLEAVE: the a2a's own post-mortem named run-order as the artifact that
# manufactured its first (wrong) "OSv declines" result. Running all OSv cells then all
# Linux cells puts hours between the arms, so any host drift lands entirely on one arm.
# Interleaving (osv r1, linux r1, osv r2, linux r2, ...) makes drift hit both arms
# equally instead of biasing the ratio. Each arm has its OWN dedicated NVMe
# (OSv nvme1n1 / Linux nvme3n1, measured equivalent within 0.4% by fio), so the pools
# persist across the interleave with no rebuild between arms.
#
# ARGS: a cell list, each as ARM:VU:REP[:MODE]; default = the full brief sweep.
set -uo pipefail
SC=/home/gburd/ws/osv/.local/scale
cd "$SC"
mkdir -p cells
SWEEP="${SWEEP:-$SC/cells/SWEEP.log}"
CELLS="${*:-}"
if [ -z "$CELLS" ]; then
  CELLS=""
  for vu in 32 64 128 192; do
    for rep in 1 2 3; do
      CELLS="$CELLS osv:$vu:$rep linux:$vu:$rep"
    done
  done
fi
echo "$(date +%H:%M:%S) SWEEP_START cells: $CELLS" | tee -a "$SWEEP"

# SCRIPT-SYNC GATE. A stale on-box copy of boot-ubuntu.sh (still naming the OSv device)
# made the Linux arm build its pool on the OSv arm's NVMe and destroyed the OSv seed --
# TWICE, because I verified the file I edited instead of the file the box would run.
# Never start a sweep without proving the box has the same bytes.
. "$SC/env.sh"
sync_fail=0
for f in boot-ubuntu.sh ubuntu-in-guest.sh linux-pg-start.sh pbmem.sh; do
  L=$(md5sum "$SC/$f" | cut -d' ' -f1)
  R=$(timeout 20 ssh $SSHO $METAL "md5sum /work/$f 2>/dev/null | cut -d' ' -f1")
  [ "$L" = "$R" ] || { echo "SYNC FAIL /work/$f local=$L box=$R" | tee -a "$SWEEP"; sync_fail=1; }
done
for f in instr.sh boot-osv.sh leverproof.sh qdisc.py fptot.py; do
  L=$(md5sum "$SC/$f" | cut -d' ' -f1)
  R=$(timeout 20 ssh $SSHO $METAL "md5sum /tmp/$f 2>/dev/null | cut -d' ' -f1")
  [ "$L" = "$R" ] || { echo "SYNC FAIL /tmp/$f local=$L box=$R" | tee -a "$SWEEP"; sync_fail=1; }
done
for f in drvinstr.sh drvdisc.py quiesce.sh hdb.sh waithist.py; do
  L=$(md5sum "$SC/$f" | cut -d' ' -f1)
  R=$(timeout 20 ssh $SSHO $DRV "md5sum /tmp/$f 2>/dev/null | cut -d' ' -f1")
  [ "$L" = "$R" ] || { echo "SYNC FAIL drv:/tmp/$f local=$L box=$R" | tee -a "$SWEEP"; sync_fail=1; }
done
if [ "$sync_fail" != 0 ]; then
  echo "REFUSING TO SWEEP: on-box scripts differ from local (see SYNC FAIL above)" | tee -a "$SWEEP"
  exit 1
fi
echo "$(date +%H:%M:%S) SCRIPT_SYNC_GATE PASS (all on-box copies byte-identical)" | tee -a "$SWEEP"

# DEVICE-ASSIGNMENT GATE: prove each arm's boot script names its OWN device.
grep -q 'file=/dev/nvme3n1' "$SC/boot-ubuntu.sh" || { echo "REFUSING: boot-ubuntu.sh must use nvme3n1" | tee -a "$SWEEP"; exit 1; }
grep -q 'POOLDEV=/dev/nvme1n1' "$SC/boot-osv.sh"  || { echo "REFUSING: boot-osv.sh must use nvme1n1" | tee -a "$SWEEP"; exit 1; }
echo "$(date +%H:%M:%S) DEVICE_GATE PASS (OSv=nvme1n1, Linux=nvme3n1)" | tee -a "$SWEEP"

for c in $CELLS; do
  ARM="${c%%:*}"; rest="${c#*:}"; VU="${rest%%:*}"; rest2="${rest#*:}"
  REP="${rest2%%:*}"; MODE="durable"
  [ "$rest2" != "$REP" ] && MODE="${rest2#*:}"
  TAG="$ARM-vu$VU-r$REP"; [ "$MODE" = nondurable ] && TAG="$ARM-nd-vu$VU-r$REP"
  echo "$(date +%H:%M:%S) START $TAG (mode=$MODE)" | tee -a "$SWEEP"
  bash "$SC/runcell-$ARM.sh" "$VU" "$REP" "$MODE" >"$SC/cells/$TAG.drive.log" 2>&1
  RC=$?
  NOPM=$(grep -oE 'System achieved [0-9]+ NOPM' "$SC/cells/$TAG.cell.txt" 2>/dev/null | grep -oE '[0-9]+' | head -1)
  P99=$(grep -oE 'NEWORD_p99_ms median=[0-9.]+' "$SC/cells/$TAG.result.txt" 2>/dev/null | head -1)
  QD=$(grep -oE 'during_run_median_pct_of_one_core=[0-9]+|ALL_SAMPLES_LOW[^)]*\)' "$SC/cells/$TAG.instr.txt" 2>/dev/null | head -1)
  DV=$(grep -oE 'DRIVER_VERDICT=[A-Z_]+' "$SC/cells/$TAG.drvinstr.txt" 2>/dev/null | head -1)
  DC=$(grep -oE 'drv_all_cpu_pct: median=[0-9]+ max=[0-9]+' "$SC/cells/$TAG.drvinstr.txt" 2>/dev/null | head -1)
  PB=$(grep -oE 'per_as_KB=[0-9]+|per_backend_MB=[0-9]+' "$SC/cells/$TAG.instr.txt" 2>/dev/null | tail -1)
  echo "$(date +%H:%M:%S) DONE  $TAG rc=$RC NOPM=${NOPM:-NONE} ${P99:-p99=NONE} qemu:${QD:-NONE} ${DV:-DRIVER_VERDICT=NONE} ${DC:-} mem:${PB:-NONE}" | tee -a "$SWEEP"
done
echo "$(date +%H:%M:%S) SWEEP_COMPLETE" | tee -a "$SWEEP"
