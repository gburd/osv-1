#!/bin/bash
# Extract every reported number for ONE cell into a single auditable line.
# ARGS: <tag>
SC=/home/gburd/ws/osv/.local/scale; T="$1"; C=$SC/cells
NOPM=$(grep -oE 'System achieved [0-9]+ NOPM' "$C/$T.cell.txt" 2>/dev/null|grep -oE '[0-9]+'|head -1)
TPM=$(grep -oE 'from [0-9]+ PostgreSQL TPM' "$C/$T.cell.txt" 2>/dev/null|grep -oE '[0-9]+'|head -1)
P99=$(grep -oE 'NEWORD_p99_ms median=[0-9.]+' "$C/$T.result.txt" 2>/dev/null|grep -oE '[0-9.]+$')
QCPU=$(grep -oE 'during_run_median_pct_of_one_core=[0-9]+' "$C/$T.instr.txt" 2>/dev/null|grep -oE '[0-9]+$')
QLOW=$(grep -oE 'ALL_SAMPLES_LOW[^)]*\)' "$C/$T.instr.txt" 2>/dev/null|head -1)
DV=$(grep -oE 'DRIVER_VERDICT=[A-Z_]+' "$C/$T.drvinstr.txt" 2>/dev/null|head -1|cut -d= -f2)
DCPU=$(grep -oE 'drv_all_cpu_pct: median=[0-9]+ max=[0-9]+' "$C/$T.drvinstr.txt" 2>/dev/null|grep -oE '[0-9]+'|tr '\n' '/'|sed 's|/$||')
DNET=$(grep -oE 'tx_Mbps median=[0-9]+ max=[0-9]+' "$C/$T.drvinstr.txt" 2>/dev/null|grep -oE '[0-9]+'|tr '\n' '/'|sed 's|/$||')
UTIL=$(grep -oE '%util: median=[0-9.]+' "$C/$T.instr.txt" 2>/dev/null|grep -oE '[0-9.]+$')
WAW=$(grep -oE 'w_await: median=[0-9.]+' "$C/$T.instr.txt" 2>/dev/null|grep -oE '[0-9.]+$')
EMF=$(grep -oE 'EMFILE_COUNT=[0-9]+' "$C/$T.instr.txt" 2>/dev/null|cut -d= -f2)
OOM=$(grep -oE 'OOM_COUNT=[0-9]+' "$C/$T.instr.txt" 2>/dev/null|cut -d= -f2)
WAIT=$(grep -oE '"[A-Za-z]+/[A-Za-z]*": *[0-9.]+' "$C/$T.result.txt" 2>/dev/null|head -3|tr '\n' ' ')
PB=""; OVF=""; MF=""; ARC=""
if [ -f "$C/$T.console.log.gz" ]; then
  zcat "$C/$T.console.log.gz" 2>/dev/null > /tmp/pc-$T.log
  FP=$(python3 $SC/fptot.py /tmp/pc-$T.log 2>/dev/null)
  PB=$(echo "$FP"|grep -oE 'PEAK_LIVE_AS: live_as=[0-9]+ .*per_backend_MB=[0-9.]+'|grep -oE 'live_as=[0-9]+|per_backend_MB=[0-9.]+'|tr '\n' ' ')
  OVF=$(echo "$FP"|grep -oE 'LAST:.*'|grep -oE 'ovfcommit_MB=[0-9]+ ovfrecycled_MB=[0-9]+ ovflive_MB=[0-9]+')
  MF=$(echo "$FP"|grep -oE 'MEMFREE_MB first=[0-9]+ min=[0-9]+ last=[0-9]+')
  ARC=$(grep -oE 'arc_size_MB=[0-9]+ arc_c_MB=[0-9]+' "$C/$T.leverproof.txt" 2>/dev/null|tail -1)
fi
[ -z "$PB" ] && PB=$(grep -oE 'client_backends=[0-9]+ .*per_backend_MB=[0-9]+' "$C/$T.instr.txt" 2>/dev/null|tail -1)
[ -z "$ARC" ] && ARC=$(grep -oE 'arc_c_current=[0-9]+|arc_max_kstat=[0-9]+' "$C/$T.leverproof.txt" 2>/dev/null|tr '\n' ' ')
# ZERO-IO SANITY: a DURABLE cell (fsync=on) that did no device IO is a BROKEN cell, not a
# result -- it means the guest wrote to a device the host was not watching, or the wrong pool.
# That is how a fabricated 1.66x "OSv wins" nearly got published in this very run.
VALID=VALID
case "$T" in *-nd-*) ;; *)
  if [ -n "$UTIL" ] && awk "BEGIN{exit !($UTIL < 0.5)}" 2>/dev/null; then
    VALID="INVALID_ZERO_IO(nvme_util=$UTIL on a durable cell)"
  fi ;;
esac
[ "${DV:-}" = DRIVER_LIMITED ] && VALID="INVALID_DRIVER_LIMITED"
[ -z "$NOPM" ] && VALID="INVALID_NO_NOPM"
echo "$T NOPM=${NOPM:-NONE} TPM=${TPM:-NONE} p99=${P99:-NONE} qemu_cpu=${QCPU:-${QLOW:-NONE}} driver=${DV:-NONE} drv_cpu=${DCPU:-NONE} drv_tx_Mbps=${DNET:-NONE} nvme_util=${UTIL:-NONE} w_await=${WAW:-NONE} EMFILE=${EMF:-?} OOM=${OOM:-?} $PB ${OVF:-} ${MF:-} arc:${ARC:-NONE} waits:${WAIT:-NONE} cell=$VALID"
