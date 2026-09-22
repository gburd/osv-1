#!/usr/bin/env python3
# ARC MEASUREMENT PROBE, bench24.
#
# The brief requires arc_c AND arc_size MEASURED per cell per arm, never an
# asserted cap (arc_c starts at allmem/32 and GROWS).  This prints the RESOLVED
# target + current size every 10s.
#
# DEFAULT-ON, no env gate: a measurement build must not depend on --env (an
# earlier run's OSV_ZFS_ARC_MAX was a silent no-op because no consumer existed).
# printf, NEVER debugf -- debugf is verbose-gated and never reaches the console.
#
# NOTE ON THE PATH, which CHANGED on this base: the aligned base carries the OSv
# platform layer IN-TREE at modules/open_zfs/osv/module/os/osv/zfs/ (1 patch
# total), where the old base SYNTHESISED it via a 45-patch series into
# modules/open_zfs/openzfs/.  So this probe patches the tracked source directly
# and no longer depends on patch-series ordering.  Instrumentation only.
# Idempotent.
import sys, os

CANDIDATES = [
    "/work/osv/modules/open_zfs/osv/module/os/osv/zfs/arc_os.c",
    "/work/osv/modules/open_zfs/openzfs/module/os/osv/zfs/arc_os.c",
]
F = next((p for p in CANDIDATES if os.path.exists(p)), None)
if F is None:
    print("FATAL: no arc_os.c found at any known path"); sys.exit(1)
print("ARC PROBE TARGET:", F)

s = open(F).read()
if "osv_arc_probe" in s:
    print("ARC PROBE ALREADY PRESENT"); sys.exit(0)

add = r'''

/* OSv ARC measurement probe (bench24).  Prints the RESOLVED ARC target/size so
 * the OSv-vs-Linux ARC comparison rests on measurement rather than an asserted
 * cap.  DEFAULT-ON; printf because debugf is verbose-gated.
 *
 * IT ALSO REPORTS THE #1513 REQUEST-SIZE HISTOGRAM, and the reason is a defect
 * this probe's first version actually had.  The counters are defined in
 * vdev_disk.c, i.e. inside libsolaris.so.  Reporting them from core/sched.cc via
 * `extern __attribute__((weak))` COMPILED AND LINKED FINE and printed NOTHING:
 * with the definition in a separate shared object the reference is an undefined
 * weak, so the compiler folds `if (&sym)` to false and eliminates the whole
 * branch as dead code.  Verified with nm: ZERO nonrot symbols in loader.elf,
 * three in libsolaris.so.  That is exactly the silent-pass class the lever rule
 * exists to prevent -- a probe that cannot fire, in a build that looks correct.
 * So the report lives in the SAME shared object as the counters. */
#include <pthread.h>
#include <unistd.h>
#include <sys/aggsum.h>
extern uint64_t zfs_dirty_data_max;

/* #1513 lever-EFFECT counters, defined in this .so by vdev_disk.c. */
extern unsigned long nonrot_req_total;
extern unsigned long nonrot_req_gt128k;
extern unsigned long nonrot_req_max_bytes;

static void *
osv_arc_probe_fn(void *arg)
{
	(void)arg;
	extern unsigned long osv_free_pages(void);
	for (;;) {
		unsigned long freep = osv_free_pages();
		int64_t arcsz = aggsum_value(&arc_sums.arcstat_size);
		printf("ARCPROBE arc_size_MB=%ld arc_c_MB=%llu arc_c_max_MB=%llu "
		    "zfs_arc_max_MB=%llu dirty_max_MB=%llu free_MB=%lu physmem_MB=%lu\n",
		    (long)(arcsz >> 20),
		    (unsigned long long)(arc_stats.arcstat_c.value.ui64 >> 20),
		    (unsigned long long)(arc_stats.arcstat_c_max.value.ui64 >> 20),
		    (unsigned long long)(zfs_arc_max >> 20),
		    (unsigned long long)(zfs_dirty_data_max >> 20),
		    (freep * 4096UL) >> 20,
		    (physmem * 4096UL) >> 20);
		/* #1513 proven by EFFECT, not by a source grep: with vdev_nonrot
		 * live, vdev_queue_aggregate() must not build aggregates above the
		 * 128 KiB non-rotating cap, so req_gt128KiB must stay 0 and max_KiB
		 * must stay <=128.  One request above 128 KiB refutes "live". */
		printf("NONROTPROBE req_total=%lu req_gt128KiB=%lu max_KiB=%lu\n",
		    nonrot_req_total, nonrot_req_gt128k,
		    nonrot_req_max_bytes >> 10);
		usleep(10000000);
	}
	return (NULL);
}

__attribute__((constructor))
static void osv_arc_probe_init(void)
{
	pthread_t th;
	(void) pthread_create(&th, NULL, osv_arc_probe_fn, NULL);
	printf("ARCPROBE: started (default-on measurement probe)\n");
}
'''
open(F, "w").write(s + add)
print("ARC PROBE APPLIED OK")
