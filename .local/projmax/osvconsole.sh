#!/bin/bash
# Fetch the OSv console with RETRIES and keep the FULL buffer.
#
# TWO measured traps this works around:
#  1. EC2 populates the serial-console buffer LAZILY: an immediate read after
#     start returns 0 bytes, and it can take >2 min. Poll patiently, because a
#     short poll silently reports "levers unverifiable", which the standing rule
#     forbids (never infer lever binding from the cmdline).
#  2. The buffer is a 64 KiB RING. The ARCPROBE/FPPROBE probes print every
#     10-30 s, so on a long-lived instance they push the BOOT HEADER (RNGPROOF,
#     WAKE_PULL, ashift/recordsize readback, "Add device instances") out of the
#     window. So the boot header must be captured EARLY (right after the box
#     starts serving) and the ARC trajectory captured LATE -- two reads, not one.
# ARGS: <outfile> <max-tries> [sleep-secs]
set -u
. /home/gburd/ws/osv/.local/projmax/env.sh
OUTF=$1; N=${2:-24}; S=${3:-20}
for i in $(seq 1 $N); do
  OUT=$(aws ec2 get-console-output --region $REGION --instance-id $OSVID --query Output --output text 2>/dev/null)
  if [ "$(printf %s "$OUT" | wc -c)" -gt 500 ]; then
    printf '%s\n' "$OUT" > "$OUTF"
    echo "CONSOLE_CAPTURED bytes=$(wc -c < "$OUTF") after $((i*S))s"
    exit 0
  fi
  sleep $S
done
echo "CONSOLE_UNAVAILABLE after $((N*S))s" | tee "$OUTF"
exit 1
