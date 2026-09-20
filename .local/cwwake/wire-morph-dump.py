#!/usr/bin/env python3
# Wire osv_morph_dump() into the zil wedge watchdog: when a LOST-WAKE is
# detected, also dump the wake-path counters. Idempotent.
import sys
F = "/work/osv/modules/open_zfs/openzfs/module/zfs/zil.c"
s = open(F).read()
if "osv_morph_dump" in s:
    print("MORPH DUMP ALREADY WIRED"); sys.exit(0)

# declare + call inside zwedge_watchdog right after the lostwake printf/inc
old = ('''		atomic_inc_64(&zwedge_lostwake);
		printf("ZWEDGE %s slot=%d zcw=%p blocked_ms=%.1f zcw_done=%d "''')
new = ('''		atomic_inc_64(&zwedge_lostwake);
		{ extern void osv_morph_dump(void); osv_morph_dump(); }
		printf("ZWEDGE %s slot=%d zcw=%p blocked_ms=%.1f zcw_done=%d "''')
assert s.count(old) == 1, "anchor %d" % s.count(old)
s = s.replace(old, new, 1)
open(F, "w").write(s)
print("MORPH DUMP WIRED OK")
