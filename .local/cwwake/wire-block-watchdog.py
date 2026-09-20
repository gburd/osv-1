#!/usr/bin/env python3
# Make the wedge watchdog fire reliably: also scan from zwedge_block (every new
# blocker during the cliff), not only from zil_commit_waiter_done (which stops
# post-deadlock). Lower threshold 300ms->150ms. Idempotent.
import sys
F = "/work/osv/modules/open_zfs/openzfs/module/zfs/zil.c"
s = open(F).read()
if "zwedge_watchdog(); /* from block */" in s:
    print("BLOCK WATCHDOG ALREADY PRESENT"); sys.exit(0)

# lower threshold
s = s.replace("if (ms < 300.0)", "if (ms < 150.0)", 1)

# forward-declare zwedge_watchdog before zwedge_block (block is defined before watchdog)
if "static void zwedge_watchdog(void);" not in s:
    s = s.replace("static int\nzwedge_block(void *zcw)\n",
                  "static void zwedge_watchdog(void);\nstatic int\nzwedge_block(void *zcw)\n", 1)

# call watchdog at the tail of zwedge_block before returning the slot
old = ('''			zwedge_tab[i].zcw = zcw;
			zwedge_tab[i].enter_ns = (uint64_t)gethrtime();
			return (i);''')
new = ('''			zwedge_tab[i].zcw = zcw;
			zwedge_tab[i].enter_ns = (uint64_t)gethrtime();
			zwedge_watchdog(); /* from block */
			return (i);''')
assert s.count(old) == 1, "block tail anchor %d" % s.count(old)
s = s.replace(old, new, 1)
open(F, "w").write(s)
print("BLOCK WATCHDOG WIRED OK")
