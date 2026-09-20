#!/usr/bin/env python3
# Per-pool memory trajectory probe: a watchdog thread in arc_os.c prints every 2s:
#   free_MB (osv_free_pages), arc_size_MB (arcstat_size), arc_c_MB (target),
#   dirty_max_MB (zfs_dirty_data_max).  Gated on OSV_MEM_PROBE=1. Names the pool.
# Idempotent. arc_sums/arc_stats come from <sys/arc_impl.h> (already included).
import sys
F = "/work/osv/modules/open_zfs/openzfs/module/os/osv/zfs/arc_os.c"
s = open(F).read()
if "osv_mem_probe" in s:
    print("MEM PROBE ALREADY PRESENT"); sys.exit(0)

add = r'''

/* OSv VU64 OOM per-pool memory trajectory probe (OSV_MEM_PROBE=1). */
#include <pthread.h>
#include <unistd.h>
#include <sys/aggsum.h>
extern uint64_t zfs_dirty_data_max;

static void *
osv_mem_probe_fn(void *arg)
{
	(void)arg;
	extern unsigned long osv_free_pages(void);
	for (;;) {
		unsigned long freep = osv_free_pages();
		int64_t arcsz = aggsum_value(&arc_sums.arcstat_size);
		printf("MEMPROBE free_MB=%lu arc_size_MB=%ld arc_c_MB=%llu "
		    "dirty_max_MB=%llu physmem_MB=%lu\n",
		    (freep * 4096UL) >> 20,
		    (long)(arcsz >> 20),
		    (unsigned long long)(arc_stats.arcstat_c.value.ui64 >> 20),
		    (unsigned long long)(zfs_dirty_data_max >> 20),
		    (physmem * 4096UL) >> 20);
		usleep(2000000);
	}
	return (NULL);
}

__attribute__((constructor))
static void osv_mem_probe_init(void)
{
	extern char *getenv(const char *);
	const char *e = getenv("OSV_MEM_PROBE");
	if (e && e[0] && e[0] != '0') {
		pthread_t th;
		(void) pthread_create(&th, NULL, osv_mem_probe_fn, NULL);
		printf("OSV_MEM_PROBE: memory trajectory probe started\n");
	}
}
'''
s = s + add
open(F, "w").write(s)
print("MEM PROBE APPLIED OK")
