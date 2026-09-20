#!/usr/bin/env python3
# Extend the wedge watchdog to report, for a done-but-asleep waiter, whether the
# waiter's wr is STILL on zcw_cv._waiters_fifo (broadcast MISSED it) vs already
# popped (fifo empty -> the thread-level wake was lost). Idempotent.
import sys
F = "/work/osv/modules/open_zfs/openzfs/module/zfs/zil.c"
s = open(F).read()
if "fifo_oldest=" in s:
    print("FIFO PROBE ALREADY PRESENT"); sys.exit(0)

old = ('''		zil_commit_waiter_t *w = (zil_commit_waiter_t *)zwedge_tab[i].zcw;
		int done = (w != NULL) ? (int)w->zcw_done : -1;
		atomic_inc_64(&zwedge_lostwake);
		{ extern void osv_morph_dump(void); osv_morph_dump(); }
		printf("ZWEDGE %s slot=%d zcw=%p blocked_ms=%.1f zcw_done=%d "
		    "(%s)\\n", done == 1 ? "LOST-WAKE" : "STILL-PENDING", i,
		    (void *)w, ms, done,
		    done == 1 ? "completion RAN, waiter STILL ASLEEP = lost wake"
		    : "completion NOT run yet (zcw_done=0)");''')
new = ('''		zil_commit_waiter_t *w = (zil_commit_waiter_t *)zwedge_tab[i].zcw;
		int done = (w != NULL) ? (int)w->zcw_done : -1;
		/* Is the waiter's wr STILL queued on the cv fifo? non-NULL =>
		 * cv_broadcast MISSED it (saw a stale/empty fifo); NULL =>
		 * it was popped+woken but the thread-level wake was lost. */
		void *fifo_oldest = (w != NULL) ?
		    (void *)w->zcw_cv._waiters_fifo.oldest : (void *)-1;
		atomic_inc_64(&zwedge_lostwake);
		{ extern void osv_morph_dump(void); osv_morph_dump(); }
		printf("ZWEDGE %s slot=%d zcw=%p blocked_ms=%.1f zcw_done=%d "
		    "fifo_oldest=%p (%s; %s)\\n",
		    done == 1 ? "LOST-WAKE" : "STILL-PENDING", i,
		    (void *)w, ms, done, fifo_oldest,
		    done == 1 ? "completion RAN, waiter STILL ASLEEP = lost wake"
		    : "completion NOT run yet (zcw_done=0)",
		    fifo_oldest == NULL ? "fifo EMPTY: wr popped, thread-wake lost"
		    : "fifo NON-EMPTY: cv_broadcast MISSED the queued wr");''')
assert s.count(old) == 1, "anchor %d" % s.count(old)
s = s.replace(old, new, 1)
open(F, "w").write(s)
print("FIFO PROBE APPLIED OK")
