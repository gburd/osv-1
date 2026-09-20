#!/usr/bin/env python3
# Insert the OSv ZIL wedge smoking-gun probe into the (already-patched) submodule zil.c.
# Idempotent: bails if the probe marker is already present.
import sys
F = "/work/osv/modules/open_zfs/openzfs/module/zfs/zil.c"
s = open(F).read()
if "OSV_ZIL_WEDGE_PROBE" in s:
    print("PROBE ALREADY PRESENT"); sys.exit(0)

# --- (1) probe block: insert right after 'static volatile uint64_t zw_wake2ent_n;' ---
anchor1 = "static volatile uint64_t zw_wake2ent_n;\n"
block = anchor1 + r'''
/*
 * OSv WEDGE smoking-gun probe (OSV_ZIL_WEDGE_PROBE=1, default OFF).  Catches the
 * ZIL completion->waiter lost wakeup: a backend blocked in the UNTIMED
 * cv_wait(&zcw->zcw_cv) whose zcw_done is already TRUE = completion RAN but the
 * OSv cross-vCPU wake was LOST.  Watchdog runs on the still-live completion
 * thread and prints the proof line while the guest is wedged.
 */
#define	ZWEDGE_SLOTS	160
struct zwedge_slot {
	volatile void *zcw;		/* the zil_commit_waiter_t being waited on */
	volatile uint64_t enter_ns;	/* gethrtime when it entered cv_wait */
	volatile int   inuse;		/* 1 while blocked in cv_wait */
};
static struct zwedge_slot zwedge_tab[ZWEDGE_SLOTS];
static volatile uint64_t zwedge_entered;   /* # untimed cv_wait entries */
static volatile uint64_t zwedge_woke;      /* # untimed cv_wait returns */
static volatile uint64_t zwedge_bcasts;    /* # zil_commit_waiter_done broadcasts */
static volatile uint64_t zwedge_lostwake;  /* # LOST-WAKE detections */
static int zwedge_on = -1;                  /* -1 unresolved, 0 off, 1 on */

static int
zwedge_enabled(void)
{
	if (zwedge_on < 0) {
		extern char *getenv(const char *);
		const char *e = getenv("OSV_ZIL_WEDGE_PROBE");
		zwedge_on = (e && e[0] && e[0] != '0') ? 1 : 0;
		printf("OSV_ZIL_WEDGE_PROBE: zil wedge smoking-gun probe=%s\n",
		    zwedge_on ? "ON" : "off");
	}
	return (zwedge_on);
}

static int
zwedge_block(void *zcw)
{
	int i;
	atomic_inc_64(&zwedge_entered);
	for (i = 0; i < ZWEDGE_SLOTS; i++) {
		if (zwedge_tab[i].inuse)
			continue;
		if (__sync_bool_compare_and_swap(&zwedge_tab[i].inuse, 0, 1)) {
			zwedge_tab[i].zcw = zcw;
			zwedge_tab[i].enter_ns = (uint64_t)gethrtime();
			return (i);
		}
	}
	return (-1);
}

static void
zwedge_unblock(int slot)
{
	atomic_inc_64(&zwedge_woke);
	if (slot >= 0 && slot < ZWEDGE_SLOTS) {
		zwedge_tab[slot].zcw = NULL;
		zwedge_tab[slot].enter_ns = 0;
		__sync_synchronize();
		zwedge_tab[slot].inuse = 0;
	}
}

/*
 * Watchdog on the (still-live) completion thread.  If a blocked waiter's
 * zcw_done is already TRUE and it has slept > 300ms, that is the lost-wakeup
 * smoking gun.  Prints a bounded number of lines.
 */
static void
zwedge_watchdog(void)
{
	static volatile uint64_t printed = 0;
	hrtime_t now = gethrtime();
	int i;
	if (printed > 12)
		return;
	for (i = 0; i < ZWEDGE_SLOTS; i++) {
		if (!zwedge_tab[i].inuse)
			continue;
		uint64_t e = zwedge_tab[i].enter_ns;
		if (e == 0)
			continue;
		double ms = (double)(now - (hrtime_t)e) / 1000000.0;
		if (ms < 300.0)
			continue;
		zil_commit_waiter_t *w = (zil_commit_waiter_t *)zwedge_tab[i].zcw;
		int done = (w != NULL) ? (int)w->zcw_done : -1;
		atomic_inc_64(&zwedge_lostwake);
		printf("ZWEDGE %s slot=%d zcw=%p blocked_ms=%.1f zcw_done=%d "
		    "(%s)\n", done == 1 ? "LOST-WAKE" : "STILL-PENDING", i,
		    (void *)w, ms, done,
		    done == 1 ? "completion RAN, waiter STILL ASLEEP = lost wake"
		    : "completion NOT run yet (zcw_done=0)");
		printed++;
		if (printed > 12)
			break;
	}
}

void zilwedge_dump(void);
__attribute__((visibility("default"))) void
zilwedge_dump(void)
{
	int i, live = 0, done_but_asleep = 0;
	hrtime_t now = gethrtime();
	for (i = 0; i < ZWEDGE_SLOTS; i++) {
		if (!zwedge_tab[i].inuse)
			continue;
		live++;
		zil_commit_waiter_t *w = (zil_commit_waiter_t *)zwedge_tab[i].zcw;
		int done = (w != NULL) ? (int)w->zcw_done : -1;
		double ms = (double)(now - (hrtime_t)zwedge_tab[i].enter_ns)
		    / 1000000.0;
		if (done == 1)
			done_but_asleep++;
		printf("RESULT ZWEDGE_SLOT i=%d zcw=%p blocked_ms=%.1f "
		    "zcw_done=%d\n", i, (void *)w, ms, done);
	}
	printf("RESULT ZWEDGE entered=%llu woke=%llu bcasts=%llu lostwake=%llu "
	    "live_blocked=%d done_but_asleep=%d\n",
	    (unsigned long long)zwedge_entered, (unsigned long long)zwedge_woke,
	    (unsigned long long)zwedge_bcasts,
	    (unsigned long long)zwedge_lostwake, live, done_but_asleep);
}
'''
assert s.count(anchor1) == 1, "anchor1 count %d" % s.count(anchor1)
s = s.replace(anchor1, block, 1)

# --- (2) count broadcasts + run watchdog after cv_broadcast in zil_commit_waiter_done ---
anchor2 = ("\tzw_last_wake_ns = (uint64_t)gethrtime();\n"
           "\tcv_broadcast(&zcw->zcw_cv);\n"
           "\tmutex_exit(&zcw->zcw_lock);\n")
repl2 = ("\tzw_last_wake_ns = (uint64_t)gethrtime();\n"
         "\tcv_broadcast(&zcw->zcw_cv);\n"
         "\tmutex_exit(&zcw->zcw_lock);\n"
         "\tif (zwedge_enabled()) {\n"
         "\t\tatomic_inc_64(&zwedge_bcasts);\n"
         "\t\tzwedge_watchdog();\n"
         "\t}\n")
assert s.count(anchor2) == 1, "anchor2 count %d" % s.count(anchor2)
s = s.replace(anchor2, repl2, 1)

# --- (3) wrap the UNTIMED cv_wait in zil_commit_waiter ---
anchor3 = "\t\t\tcv_wait(&zcw->zcw_cv, &zcw->zcw_lock);\n"
repl3 = ("\t\t\tif (zwedge_enabled()) {\n"
         "\t\t\t\tint zws = zwedge_block(zcw);\n"
         "\t\t\t\tcv_wait(&zcw->zcw_cv, &zcw->zcw_lock);\n"
         "\t\t\t\tzwedge_unblock(zws);\n"
         "\t\t\t} else {\n"
         "\t\t\t\tcv_wait(&zcw->zcw_cv, &zcw->zcw_lock);\n"
         "\t\t\t}\n")
# there should be exactly one untimed cv_wait at this indentation
assert s.count(anchor3) == 1, "anchor3 count %d" % s.count(anchor3)
s = s.replace(anchor3, repl3, 1)

open(F, "w").write(s)
print("PROBE INSERTED OK")
