#!/usr/bin/env python3
# Spawn a dedicated watchdog thread the first time the probe is enabled, so the
# fifo/done scan runs every 200ms independently of the (deadlocked) ZIL paths.
# Guaranteed to catch the wedge. Idempotent.
import sys
F = "/work/osv/modules/open_zfs/openzfs/module/zfs/zil.c"
s = open(F).read()
if "zwedge_thread_fn" in s:
    print("WATCHDOG THREAD ALREADY PRESENT"); sys.exit(0)

# add pthread include if missing
if "#include <pthread.h>" not in s:
    s = s.replace("#include <sys/zil_impl.h>\n",
                  "#include <sys/zil_impl.h>\n#include <pthread.h>\n#include <unistd.h>\n", 1)

# add the thread fn + spawner just before zwedge_enabled()
anchor = "static int\nzwedge_enabled(void)\n{"
block = '''static void zwedge_scan_all(void);
static void *
zwedge_thread_fn(void *arg)
{
	(void)arg;
	for (;;) {
		usleep(200000); /* 200ms */
		zwedge_scan_all();
	}
	return (NULL);
}

static int
zwedge_enabled(void)
{'''
assert s.count(anchor) == 1, "enabled anchor %d" % s.count(anchor)
s = s.replace(anchor, block, 1)

# start the thread once, inside zwedge_enabled when turning ON
old_on = ('''		zwedge_on = (e && e[0] && e[0] != '0') ? 1 : 0;
		printf("OSV_ZIL_WEDGE_PROBE: zil wedge smoking-gun probe=%s\\n",
		    zwedge_on ? "ON" : "off");''')
new_on = ('''		zwedge_on = (e && e[0] && e[0] != '0') ? 1 : 0;
		printf("OSV_ZIL_WEDGE_PROBE: zil wedge smoking-gun probe=%s\\n",
		    zwedge_on ? "ON" : "off");
		if (zwedge_on) {
			pthread_t th;
			(void) pthread_create(&th, NULL, zwedge_thread_fn, NULL);
			printf("OSV_ZIL_WEDGE_PROBE: watchdog thread started\\n");
		}''')
assert s.count(old_on) == 1, "on anchor %d" % s.count(old_on)
s = s.replace(old_on, new_on, 1)

# zwedge_scan_all: a standalone scan that reports done+asleep with fifo state,
# defined just after zwedge_watchdog(). Reuse the same body but scan ALL slots
# (done or not) once, printing a compact summary + any done-but-asleep detail.
anchor_wd_end = '''void zilwedge_dump(void);'''
scan = '''static void
zwedge_scan_all(void)
{
	static volatile uint64_t printed = 0;
	hrtime_t now = gethrtime();
	int i, live = 0, done_asleep = 0, notdone = 0;
	void *first_done_zcw = NULL; double first_done_ms = 0; void *first_done_fifo = (void *)-1;
	for (i = 0; i < ZWEDGE_SLOTS; i++) {
		if (!zwedge_tab[i].inuse)
			continue;
		uint64_t e = zwedge_tab[i].enter_ns;
		if (e == 0)
			continue;
		double ms = (double)(now - (hrtime_t)e) / 1000000.0;
		if (ms < 150.0)
			continue;
		live++;
		zil_commit_waiter_t *w = (zil_commit_waiter_t *)zwedge_tab[i].zcw;
		int done = (w != NULL) ? (int)w->zcw_done : -1;
		if (done == 1) {
			done_asleep++;
			if (first_done_zcw == NULL) {
				first_done_zcw = (void *)w;
				first_done_ms = ms;
				first_done_fifo = (w != NULL) ?
				    (void *)w->zcw_cv._waiters_fifo.oldest : (void *)-1;
			}
		} else {
			notdone++;
		}
	}
	if (done_asleep > 0 && printed < 6) {
		printed++;
		atomic_inc_64(&zwedge_lostwake);
		{ extern void osv_morph_dump(void); osv_morph_dump(); }
		printf("ZWEDGE-SCAN live_stuck=%d done_but_asleep=%d notdone=%d "
		    "first_done zcw=%p blocked_ms=%.1f fifo_oldest=%p (%s)\\n",
		    live, done_asleep, notdone, first_done_zcw, first_done_ms,
		    first_done_fifo,
		    first_done_fifo == NULL ?
		    "fifo EMPTY: wr popped, thread-wake lost" :
		    "fifo NON-EMPTY: cv_broadcast MISSED the queued wr");
	}
}

void zilwedge_dump(void);'''
assert s.count(anchor_wd_end) == 1, "zilwedge_dump anchor %d" % s.count(anchor_wd_end)
s = s.replace(anchor_wd_end, scan, 1)

open(F, "w").write(s)
print("WATCHDOG THREAD APPLIED OK")
