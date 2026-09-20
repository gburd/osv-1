#!/usr/bin/env python3
"""FPTOT/FPROW parser for the footprint probe.

TRAP this handles: the probe emits each field with debug_early_u64, which writes ONE
FIELD PER LINE and formats the value as ZERO-PADDED HEX with no 0x prefix
(e.g. " per_as_KB=0000000000002800" is hex 0x2800 = 10240 KB = 10.0 MB). So a naive
`grep FPTOT` sees only "live_as=..." and a naive int() reads the value wrong by orders
of magnitude. Both mistakes would silently fake the headline per-backend number, so the
parse is done here once, explicitly.

Reads a console log, reconstructs each FPTOT record between 'FPTOT' and 'FPTOTEND',
and reports the per-backend footprint. ARGS: <console.log> [--all]
"""
import sys, re

path = sys.argv[1]
show_all = '--all' in sys.argv

txt = open(path, 'rb').read().decode('utf-8', 'replace').replace('\r', '\n')
lines = txt.split('\n')

records, cur, inrec = [], {}, False
for ln in lines:
    s = ln.strip()
    if s.startswith('FPTOT') and 'FPTOTEND' not in s:
        inrec, cur = True, {}
        s = s[len('FPTOT'):].strip()
        # do NOT `continue` here: 'FPTOT live_as=...' carries live_as on the SAME line,
        # so skipping it drops the field and every record fails the completeness check.
        # Fall through to the field scanner below with the prefix removed.
    if 'FPTOTEND' in s:
        # Only a record CLOSED by FPTOTEND is complete. A record still being written
        # when the log was read has missing fields that would parse as 0 and silently
        # report per_backend_MB=0.0 / memfree_MB=0 -- a fake number. Require the
        # terminator AND the last field the probe emits (memtotal_MB).
        if inrec and cur and 'memtotal_MB' in cur:
            records.append(cur)
        inrec, cur = False, {}
        continue
    if inrec:
        for m in re.finditer(r'([A-Za-z_0-9]+)=([0-9a-fA-F]+)', s):
            k, v = m.group(1), m.group(2)
            try:
                cur[k] = int(v, 16)   # debug_early_u64 prints HEX, zero-padded
            except ValueError:
                pass

if not records:
    print('NO_FPTOT_RECORDS'); sys.exit(0)

def fmt(r):
    live = r.get('live_as', 0)
    per_kb = r.get('per_as_KB', 0)
    return ('live_as=%d forks=%d reaps=%d per_backend_MB=%.1f (per_as_KB=%d) '
            'acct_MB=%d priv_MB=%d pt_MB=%d ovf_MB=%d cowarena_MB=%d '
            'ovfcommit_MB=%d ovfrecycled_MB=%d ovflive_MB=%d ovfforeign=%d '
            'arena_bump_MB=%d arena_slots=%d memfree_MB=%d memtotal_MB=%d'
            % (live, r.get('forks',0), r.get('reaps',0), per_kb/1024.0, per_kb,
               r.get('acct_MB',0), r.get('priv_MB',0), r.get('pt_MB',0), r.get('ovf_MB',0),
               r.get('cowarena_MB',0), r.get('ovfcommit_MB',0), r.get('ovfrecycled_MB',0),
               r.get('ovflive_MB',0), r.get('ovfforeign',0), r.get('arena_bump_MB',0),
               r.get('arena_slots',0), r.get('memfree_MB',0), r.get('memtotal_MB',0)))

if show_all:
    for r in records:
        print(fmt(r))

# The headline: the record with the MOST live address spaces (peak concurrency), which is
# where per-backend footprint matters, plus the last record.
peak = max(records, key=lambda r: r.get('live_as', 0))
print('N_RECORDS=%d' % len(records))
print('PEAK_LIVE_AS: ' + fmt(peak))
print('LAST:         ' + fmt(records[-1]))
# Monotonic-decline watch (leak #2 / footprint regression): does memfree fall steadily?
free = [r.get('memfree_MB', 0) for r in records if 'memfree_MB' in r]
if len(free) >= 4:
    print('MEMFREE_MB first=%d min=%d last=%d max=%d  (a steady monotonic fall = leak/footprint regression)'
          % (free[0], min(free), free[-1], max(free)))
