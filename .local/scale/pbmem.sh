#!/bin/bash
# LINUX per-backend memory, the matched counterpart to OSv's FPTOT per_as_KB.
# Runs INSIDE the Ubuntu guest. Reports PRIVATE memory per client backend so the
# comparison is apples-to-apples: OSv's per_as_KB counts per-AS PRIVATE pages
# (COW'd arena + page tables + privatized stacks + overflow), so on Linux we take
# smaps_rollup Private_Clean+Private_Dirty (shared_buffers excluded by construction).
NB=0; TOTPRIV=0
for p in $(pgrep -f 'postgres: .* tpcc' 2>/dev/null; pgrep -f 'postgres.*tpcc' 2>/dev/null); do
  R=$(awk '/^Private_Clean|^Private_Dirty/{s+=$2} END{print s+0}' /proc/$p/smaps_rollup 2>/dev/null)
  [ -z "$R" ] && continue
  [ "$R" = 0 ] && continue
  TOTPRIV=$((TOTPRIV+R)); NB=$((NB+1))
done
echo "LINUX_PBMEM client_backends=$NB total_private_kB=$TOTPRIV per_backend_KB=$([ $NB -gt 0 ] && echo $((TOTPRIV/NB)) || echo 0) per_backend_MB=$([ $NB -gt 0 ] && echo $((TOTPRIV/NB/1024)) || echo 0)"
echo "MEMINFO free_MB=$(awk '/MemFree/{print int($2/1024)}' /proc/meminfo) avail_MB=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
echo "ARC arc_c_MB=$(awk '/^c /{print int($3/1048576)}' /proc/spl/kstat/zfs/arcstats 2>/dev/null) arc_size_MB=$(awk '/^size/{print int($3/1048576)}' /proc/spl/kstat/zfs/arcstats 2>/dev/null)"
echo "ALLBACKENDS=$(pgrep -c -f 'postgres' 2>/dev/null)"
