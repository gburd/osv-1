#!/usr/bin/env python3
"""DRIVER-saturation discriminator. Reads /tmp/drvcpu-<TAG>.txt and decides whether the
cell was DRIVER-LIMITED (so its NOPM says nothing about the guest) or driver-headroom-OK.

Rule (from the brief): a cell whose driver was >70% all-CPU busy, or whose NIC was near
line rate, is DRIVER-LIMITED / INVALID and must not enter the headline table.
c5.9xlarge = 36 vCPU, 10 Gbps baseline (up to 10 Gbit sustained). Line-rate threshold
set at 7000 Mbps (70% of 10 Gbps) on either direction.
ARG: TAG"""
import sys, re, statistics as s

tag = sys.argv[1]
path = '/tmp/drvcpu-%s.txt' % tag
try:
    lines = [l for l in open(path) if 'drv_all_cpu_pct' in l]
except Exception:
    print('NO_DRVCPU_FILE'); sys.exit(0)

def col(name, cast=int):
    out = []
    for l in lines:
        m = re.search(r'\b%s=("?)([-0-9.]+)\1' % name, l)
        if m:
            out.append(cast(m.group(2)))
    return out

allcpu = col('drv_all_cpu_pct')
hdb    = col('hdb_cpu_pct_of_one_core')
rx     = col('rx_Mbps')
tx     = col('tx_Mbps')
rxp    = col('rx_pps')
txp    = col('tx_pps')
ncpu   = col('ncpu')
ncpu   = ncpu[0] if ncpu else 36

if not allcpu:
    print('NO_SAMPLES'); sys.exit(0)

# The run window: exclude leading/trailing idle (samples where hdb ~0), so the
# reported numbers describe the loaded period, not the boot/teardown tails.
busy_idx = [i for i, h in enumerate(hdb) if h and h > 50] if hdb else list(range(len(allcpu)))
if len(busy_idx) < 3:
    busy_idx = list(range(len(allcpu)))
sel = lambda v: [v[i] for i in busy_idx if i < len(v)]

a, h = sel(allcpu), sel(hdb)
r, t = sel(rx), sel(tx)
CPU_LIMIT, NET_LIMIT_MBPS = 70, 7000
amed, amax = s.median(a), max(a)
rmax = max(r) if r else 0
tmax = max(t) if t else 0
netmax = max(rmax, tmax)

verdict = 'DRIVER_OK'
why = []
if amax > CPU_LIMIT:
    verdict = 'DRIVER_LIMITED'; why.append('all_cpu_max=%d%%>%d%%' % (amax, CPU_LIMIT))
elif amed > CPU_LIMIT * 0.8:
    verdict = 'DRIVER_NEAR_LIMIT'; why.append('all_cpu_median=%d%%' % amed)
if netmax > NET_LIMIT_MBPS:
    verdict = 'DRIVER_LIMITED'; why.append('net_max=%dMbps>%dMbps' % (netmax, NET_LIMIT_MBPS))

print('DRIVER_VERDICT=%s %s' % (verdict, (' '.join(why) or 'headroom ok')))
print('drv_all_cpu_pct: median=%d max=%d  (ncpu=%d, limit %d%%)' % (amed, amax, ncpu, CPU_LIMIT))
print('hdb_cpu_pct_of_one_core: median=%d max=%d  (ceiling %d00 for %d vCPU)'
      % (s.median(h) if h else 0, max(h) if h else 0, ncpu, ncpu))
print('net rx_Mbps median=%d max=%d | tx_Mbps median=%d max=%d  (line-rate flag %dMbps)'
      % (s.median(r) if r else 0, rmax, s.median(t) if t else 0, tmax, NET_LIMIT_MBPS))
if rxp and txp:
    rp, tp = sel(rxp), sel(txp)
    print('net rx_pps median=%d max=%d | tx_pps median=%d max=%d'
          % (s.median(rp), max(rp), s.median(tp), max(tp)))
print('n_run_samples=%d of %d total' % (len(a), len(allcpu)))
