#!/usr/bin/env python3
# OSV_ZIL_WAIT_TIMEOUT=1 A/B + mitigation: replace the UNTIMED cv_wait(&zcw_cv)
# in zil_commit_waiter with a BOUNDED cv_timedwait_hires loop. If the completion's
# cv_broadcast wake is lost, the waiter still wakes on the timeout, re-checks the
# while(!zcw_done) condition (zcw_done is already TRUE), and proceeds - breaking
# the deadlock. If the wedge DISAPPEARS -> confirms the lost wake is the zcw_cv
# signal to a blocked waiter whose condition is already satisfied (a genuine lost
# condvar wakeup), and this bounded wait is a correct self-healing mitigation.
# Idempotent. Gated so default (off) keeps the untimed wait.
import sys
F = "/work/osv/modules/open_zfs/openzfs/module/zfs/zil.c"
s = open(F).read()
if "zil_wait_timeout_enabled" in s:
    print("WAIT_TIMEOUT ALREADY PRESENT"); sys.exit(0)

# helper near the wedge probe enabled fn
anchor = "static int\nzwedge_enabled(void)\n{"
helper = '''static int
zil_wait_timeout_enabled(void)
{
	static int v = -1;
	if (v < 0) {
		extern char *getenv(const char *);
		const char *e = getenv("OSV_ZIL_WAIT_TIMEOUT");
		v = (e && e[0] && e[0] != '0') ? 1 : 0;
		printf("OSV_ZIL_WAIT_TIMEOUT: bounded ZIL commit wait=%s\\n",
		    v ? "ON (self-healing, 1ms recheck)" : "off (untimed cv_wait)");
	}
	return (v);
}

static int
zwedge_enabled(void)
{'''
assert s.count(anchor) == 1, "enabled anchor %d" % s.count(anchor)
s = s.replace(anchor, helper, 1)

# replace the (already wedge-probe-wrapped) untimed cv_wait block. The current
# structure after the wedge probe is:
#   if (zwedge_enabled()) { int zws = zwedge_block(zcw); cv_wait(...); zwedge_unblock(zws); }
#   else { cv_wait(...); }
old = '''			if (zwedge_enabled()) {
				int zws = zwedge_block(zcw);
				cv_wait(&zcw->zcw_cv, &zcw->zcw_lock);
				zwedge_unblock(zws);
			} else {
				cv_wait(&zcw->zcw_cv, &zcw->zcw_lock);
			}'''
new = '''			int zws = zwedge_enabled() ? zwedge_block(zcw) : -1;
			if (zil_wait_timeout_enabled()) {
				/* Self-healing bounded wait: recheck zcw_done
				 * every 1ms even if the cv_broadcast wake is
				 * lost.  cv_timedwait_hires with a relative 1ms
				 * deadline (flag 0 -> add gethrtime()). */
				(void) cv_timedwait_hires(&zcw->zcw_cv,
				    &zcw->zcw_lock, MSEC2NSEC(1), USEC2NSEC(1),
				    0);
			} else {
				cv_wait(&zcw->zcw_cv, &zcw->zcw_lock);
			}
			if (zws >= 0)
				zwedge_unblock(zws);'''
assert s.count(old) == 1, "cv_wait block anchor %d" % s.count(old)
s = s.replace(old, new, 1)
open(F, "w").write(s)
print("WAIT_TIMEOUT APPLIED OK")
