#!/usr/bin/env python3
# qemu-cpu discriminator: read /work/qemucpu-<TAG>.txt, print during-run median (samples >100pct of
# one core) vs ALL_SAMPLES_LOW (the low-mode / wakeup-starvation signature). ARG: TAG
import sys, statistics as s
tag = sys.argv[1]
try:
    v = [int(l.split('=')[1].split()[0]) for l in open('/work/qemucpu-%s.txt' % tag) if 'qemu_cpu' in l]
except Exception:
    print('NO_QEMUCPU_FILE'); sys.exit(0)
hi = [x for x in v if x > 100]
if hi:
    print('during_run_median_pct_of_one_core=%d n_hi=%d min_hi=%d max_hi=%d (ceiling 3200 = 32 vCPU)'
          % (s.median(hi), len(hi), min(hi), max(hi)))
else:
    print('ALL_SAMPLES_LOW n=%d max=%d (LOW-MODE: no sample >100pct-of-one-core => guest WAITING)'
          % (len(v), max(v) if v else 0))
