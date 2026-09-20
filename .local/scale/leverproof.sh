#!/bin/bash
# RESOLVED-LEVER PROOF for the OSv arm. MANDATORY per the env-audit rule: an A/B is
# INVALID unless the RESOLVED value of every lever is printed to the console and
# verified PER ARM. Never infer binding from the command line.
#
# CRITICAL: the BOOT CMDLINE echo line contains every env NAME, so a naive grep for
# the lever name matches the command line and FAKES proof. Every grep below therefore
# EXCLUDES the cmdline/BOOT lines and only accepts a line the KERNEL emitted
# (printf/debug_early -- never debugf, which is verbose-gated and silent).
# ARGS: [console log path]
LOG="${1:-/work/console-run.log}"
K() { grep -hE "$1" "$LOG" 2>/dev/null | grep -vE '^BOOT |BOOT CMDLINE|BOOT IMG|^Cmdline:' | head -"${2:-1}"; }

echo "===== RESOLVED-LEVER PROOF (source: $LOG) ====="
echo "--- boot line as GIVEN (audit only, NOT proof of binding) ---"
grep -m1 'BOOT IMG:' "$LOG" 2>/dev/null
grep -m1 'BOOT IMG SHA' "$LOG" 2>/dev/null
echo "--- KERNEL-EMITTED resolved values (this IS the proof) ---"
P=$(K 'FORKARENA ovf_recycle'); echo "FOOTPRINT_FIX(ovf_recycle): ${P:-NO-LINE-YET (prints on first overflow free; check again under load)}"
P=$(K 'FPPROBE started');      echo "FP_PROBE: ${P:-UNPROVEN}"
P=$(K '^WAKE_PULL');           echo "OSV_WAKE_PULL: ${P:-UNPROVEN}"
P=$(K '^WAKE_LOCAL');          echo "OSV_WAKE_LOCAL: ${P:-(absent)}"
P=$(K 'OSV_BLK_MQ_COMPLETE:'); echo "OSV_BLK_MQ_COMPLETE: ${P:-UNPROVEN}"
P=$(K 'OSV_ZIO_INTR_THREADS' 2); echo "OSV_ZIO_INTR_THREADS: ${P:-(absent)}"
P=$(K 'OSV_ZIL_FLUSH_INLINE'); echo "OSV_ZIL_FLUSH_INLINE: ${P:-(absent)}"
P=$(K 'OSV_ZIL_COMMIT_TIMEOUT_PCT'); echo "OSV_ZIL_COMMIT_TIMEOUT_PCT: ${P:-(absent)}"
P=$(K 'OSV_ZIL_WAKE_UNLOCKED'); echo "OSV_ZIL_WAKE_UNLOCKED: ${P:-(absent)}"
echo "--- FORKFLAG resolved values (the fork levers report their own resolution) ---"
grep -hE 'FORKFLAG' "$LOG" 2>/dev/null | head -8 || echo "  (none)"
echo "--- ARC RESOLVED, MEASURED (OSV_ZFS_ARC_MAX is ABSENT on this base: zfs_arc_max_MB=0"
echo "--- proves the knob has no consumer here, so ARC is measured, never assumed) ---"
grep -hE 'ARCPROBE arc' "$LOG" 2>/dev/null | tail -2 || echo "  UNPROVEN: no ARCPROBE line"
echo "--- OSv version + boot ---"
K 'OSv v0\.' ; K 'Booted up in'
echo "--- FPTOT (footprint probe: per_as_KB = the per-backend number) ---"
grep -hE 'FPTOT' "$LOG" 2>/dev/null | tail -1 || echo "  (no FPTOT yet)"
echo "===== END LEVER PROOF ====="
