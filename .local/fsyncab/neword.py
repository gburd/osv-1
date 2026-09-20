#!/usr/bin/env python3
"""Aggregate NEWORD stats across all virtual users in an xtprofile log.
Reports call-weighted mean P99 and total NEWORD calls. ARGS: <xtprof.log>"""
import sys, re
txt = open(sys.argv[1]).read()
blocks = txt.split(">>>>> PROC: NEWORD")
calls_tot = 0
p99s = []  # (p99, calls)
maxes = []
for b in blocks[1:]:
    mc = re.search(r"CALLS:\s*(\d+)", b)
    mp = re.search(r"P99:\s*([\d.]+)ms", b)
    mm = re.search(r"MAX:\s*([\d.]+)ms", b)
    if mc and mp:
        c = int(mc.group(1)); calls_tot += c
        p99s.append((float(mp.group(1)), c))
        if mm: maxes.append(float(mm.group(1)))
if p99s:
    wsum = sum(p*c for p,c in p99s); csum = sum(c for _,c in p99s)
    call_weighted_p99 = wsum/csum
    print(f"NEWORD total_calls={calls_tot}  vusers={len(p99s)}  "
          f"call-weighted P99={call_weighted_p99:.3f}ms  "
          f"min_p99={min(p for p,_ in p99s):.3f}ms  max_p99={max(p for p,_ in p99s):.3f}ms  "
          f"max_latency={max(maxes) if maxes else 0:.3f}ms")
else:
    print("NEWORD: no data")
