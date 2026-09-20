#!/usr/bin/env python3
# Extend the MEMPROBE sampler with the FOOTPRINT breakdown dump.
# Every OSV_FP_INTERVAL (default 5) seconds it calls osv_fp_dump() so the per-AS
# per-backend attribution table lands on the console interleaved with the
# free/ARC/dirty trajectory. Gated on OSV_FP_PROBE=1 (MEMPROBE gate unchanged).
import sys
F = "/work/osv/modules/open_zfs/openzfs/module/os/osv/zfs/arc_os.c"
s = open(F).read()

if "osv_mem_probe" not in s:
    # apply the base mem probe first
    add = r'''

/* OSv VU64 OOM per-pool memory trajectory probe (OSV_MEM_PROBE=1). */
#include <pthread.h>
#include <unistd.h>
#include <sys/aggsum.h>
extern uint64_t zfs_dirty_data_max;
extern void osv_fp_dump(void);

static void *
osv_mem_probe_fn(void *arg)
{
	(void)arg;
	extern unsigned long osv_free_pages(void);
	const char *fpi = getenv("OSV_FP_INTERVAL");
	int every = (fpi && fpi[0]) ? atoi(fpi) : 3;   /* dump FP every Nth sample */
	const char *fpp = getenv("OSV_FP_PROBE");
	int fpon = (fpp && fpp[0] && fpp[0] != '0');
	unsigned long n = 0;
	for (;;) {
		unsigned long freep = osv_free_pages();
		int64_t arcsz = aggsum_value(&arc_sums.arcstat_size);
		printf("MEMPROBE t=%lu free_MB=%lu arc_size_MB=%ld arc_c_MB=%llu "
		    "dirty_max_MB=%llu physmem_MB=%lu\n",
		    n * 2UL,
		    (freep * 4096UL) >> 20,
		    (long)(arcsz >> 20),
		    (unsigned long long)(arc_stats.arcstat_c.value.ui64 >> 20),
		    (unsigned long long)(zfs_dirty_data_max >> 20),
		    (physmem * 4096UL) >> 20);
		if (fpon && every > 0 && (n % (unsigned long)every) == 0)
			osv_fp_dump();
		n++;
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
    print("MEM+FP PROBE APPLIED OK")
    sys.exit(0)

if "osv_fp_dump" in s:
    print("FP DUMP ALREADY WIRED"); sys.exit(0)
print("FATAL: mem probe present but not FP-aware -- unexpected state")
sys.exit(1)
