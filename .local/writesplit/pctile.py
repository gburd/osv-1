#!/usr/bin/env python3
# Extract p50/p99 from bpftrace lhist/hist buckets in a probe output file.
import sys, re

def parse_hist(lines, name):
    # returns list of (lo, hi, count); hi=None for open-ended log2 top bucket
    out = []
    grab = False
    for ln in lines:
        if ln.strip().startswith('@'+name+':') or ln.strip() == '@'+name+': ':
            grab = True; continue
        if grab:
            if ln.strip().startswith('@'):  # next map
                break
            m = re.match(r'\s*\[(\d+[KMG]?),\s*(\d+[KMG]?)\)\s+(\d+)', ln)
            m2 = re.match(r'\s*\[(\d+[KMG]?),\s*\.\.\.\)\s+(\d+)', ln)
            def num(s):
                mul=1
                if s.endswith('K'): mul=1000; s=s[:-1]
                elif s.endswith('M'): mul=1000000; s=s[:-1]
                elif s.endswith('G'): mul=1000000000; s=s[:-1]
                return int(s)*mul
            if m:
                out.append((num(m.group(1)), num(m.group(2)), int(m.group(3))))
            elif m2:
                out.append((num(m2.group(1)), None, int(m2.group(2))))
    return out

def pct(buckets, p):
    total = sum(c for _,_,c in buckets)
    if total == 0: return None
    target = total * p
    cum = 0
    for lo,hi,c in buckets:
        if cum + c >= target:
            # linear interp within bucket
            if hi is None: return lo  # open bucket: report lower bound
            frac = (target - cum)/c if c else 0
            return lo + (hi-lo)*frac
        cum += c
    return buckets[-1][0]

fn = sys.argv[1]
lines = open(fn).read().splitlines()
for metric, prefer in [('write','write_us_lin'),('flush','flush_us_lin')]:
    b = parse_hist(lines, prefer)
    # fall back to log2 hist if linear empty at tail
    logb = parse_hist(lines, metric+'_us')
    # use linear for body; if p99 falls in last linear bucket, refine with log2
    p50 = pct(b, 0.50); p99 = pct(b, 0.99)
    # if p99 is in/after the last linear bucket, use log2 hist for the tail
    if b:
        last_hi = b[-1][1]
        tot_lin = sum(c for _,_,c in b)
        tot_log = sum(c for _,_,c in logb)
        if p99 is not None and last_hi is not None and p99 >= last_hi - 1:
            p99l = pct(logb, 0.99)
            if p99l: p99 = p99l
    print(f"{metric}: p50={p50:.0f}us p99={p99:.0f}us" if p50 and p99 else f"{metric}: n/a")
