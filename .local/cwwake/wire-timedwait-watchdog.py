#!/usr/bin/env python3
# Fire the wedge watchdog from the OPENED-branch cv_timedwait_hires return in
# zil_commit_waiter: during the wedge the lead committer keeps timing out and
# re-waiting, so its scans reliably observe the stuck untimed waiters + dump the
# fifo state. Idempotent.
import sys
F = "/work/osv/modules/open_zfs/openzfs/module/zfs/zil.c"
s = open(F).read()
if "zwedge_watchdog(); /* from timedwait */" in s:
    print("TIMEDWAIT WATCHDOG ALREADY PRESENT"); sys.exit(0)

# right after the timed-wait accounting block, before "if (rc != -1 || zcw->zcw_done)"
old = ('''			if (rc != -1 || zcw->zcw_done)
				continue;''')
new = ('''			if (zwedge_enabled())
				zwedge_watchdog(); /* from timedwait */
			if (rc != -1 || zcw->zcw_done)
				continue;''')
assert s.count(old) == 1, "anchor %d" % s.count(old)
s = s.replace(old, new, 1)
open(F, "w").write(s)
print("TIMEDWAIT WATCHDOG WIRED OK")
