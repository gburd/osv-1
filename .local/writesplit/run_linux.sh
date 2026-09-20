#!/bin/bash
# Linux-ZFS arm runner: for each thread count, start probe, run syncwrite 30s, stop, save.
set -e
DIR=/zilbench/sw
OUT=/tmp/writesplit_linux
mkdir -p $OUT
for THR in "$@"; do
  echo "======== LINUX t=$THR ========"
  sudo rm -f $DIR/*.dat
  sudo bpftrace /tmp/lwb_probe.bt > $OUT/probe_t${THR}.out 2>$OUT/probe_t${THR}.err &
  BP=$!
  sleep 2
  /tmp/syncwrite $DIR $THR 30 | tee $OUT/work_t${THR}.out
  sleep 1
  sudo kill -INT $BP 2>/dev/null || true
  wait $BP 2>/dev/null || true
  echo "---- probe summary t=$THR ----"
  grep -E "max_inflight|mean_inflight|flush_count" $OUT/probe_t${THR}.out || true
done
echo "DONE"
