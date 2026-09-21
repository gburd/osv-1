#!/usr/bin/env python3
# ARC MEASUREMENT PROBE for the OSv arm.
#
# WHY: OSV_ZFS_ARC_MAX does NOT EXIST on bank/fork-footprint-reduction-signed (it lives
# only on gh-fork/bench/zil-hires-ab, commits b7dff520d/98b5e58c4). So --env=OSV_ZFS_ARC_MAX
# is a SILENT NO-OP on this base: there is no consumer to read it. That is exactly the
# failure mode the env audit documented, and it means "matched 32GiB ARC both sides"
# CANNOT be asserted for this run -- OSv's ARC must be MEASURED and Linux matched to it
# (or the asymmetry documented with numbers).
#
# This probe prints the RESOLVED ARC target + current size to the console every 10s.
# DEFAULT-ON (no env gate) so it cannot be defeated by the env trap -- this is a
# measurement build. printf reaches the console; debugf would not (verbose-gated).
# Instrumentation only: reads counters, changes no ZFS behaviour.
# Idempotent.
import sys
F = "/work/osv/modules/open_zfs/openzfs/module/os/osv/zfs/arc_os.c"
s = open(F).read()
if "osv_arc_probe" in s:
    print("ARC PROBE ALREADY PRESENT"); sys.exit(0)

add = r'''

/* OSv ARC measurement probe: prints the RESOLVED ARC target/size so an
 * OSv-vs-Linux ARC comparison rests on measurement, not on a knob that does not
 * exist on this base.  DEFAULT-ON (a measurement build must not depend on --env).
 * printf (not debugf): debugf is verbose-gated and never reaches the console. */
#include <pthread.h>
#include <unistd.h>
#include <sys/aggsum.h>
extern uint64_t zfs_dirty_data_max;

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
s = s + add
open(F, "w").write(s)
print("ARC PROBE APPLIED OK")
