// SPDX-License-Identifier: CDDL-1.0
/*
 * Copyright (c) 2026, OSv contributors. All rights reserved.
 *
 * OpenZFS-OSv Compatibility Shim
 *
 * This file bridges the OpenZFS platform API expectations with
 * OSv kernel interfaces. It provides implementations of functions
 * that OpenZFS expects from the OS layer but that don't have
 * direct equivalents in OSv.
 */

#include <sys/zfs_context.h>
#include <sys/spa.h>
#include <sys/arc.h>
#include <sys/abd.h>
#include <sys/abd_impl.h>

/*
 * Memory information.
 * OpenZFS uses these to determine ARC sizing and throttling.
 * physmem is declared in netport.h as size_t.
 */

/*
 * OSv VM pressure detection.
 * Returns true when the system is under memory pressure
 * and ARC should shrink.
 */
extern boolean_t vm_throttling_needed(void);

/*
 * Pool sync on last unmount.
 * Called from zfs_vfsops when the last ZFS dataset is unmounted.
 */
extern void spa_sync_allpools(void);

/*
 * Dentry release for unmount.
 * OSv uses dentries instead of FreeBSD vnodes.
 */
extern void release_mp_dentries(void *vfsp);

/*
 * ZFS driver state tracking.
 */
boolean_t zfs_driver_initialized = B_FALSE;

/*
 * nocacheflush tunable -- now defined by OpenZFS vdev.c via ZFS_MODULE_PARAM.
 */

/*
 * Active filesystem count for pool sync optimization.
 */
uint32_t zfs_active_fs_count = 0;

/*
 * panicstr - pointer to panic message (NULL when not panicking).
 * Used by compat mutex.h MUTEX_NOT_HELD macro.
 */
const char *panicstr = NULL;

/*
 * utsname wrapper.
 * The old compat layer defines a global `utsname` variable.
 * OpenZFS calls utsname() as a function. We bridge the two.
 */
extern struct opensolaris_utsname utsname;
utsname_t *
osv_utsname(void)
{
	return (&utsname);
}

/*
 * spl_panic - core assertion failure handler.
 * Called by VERIFY/ASSERT macros.
 */
void
spl_panic(const char *file, const char *func, int line,
    const char *fmt, ...)
{
	va_list ap;

	printf("SPL PANIC at %s:%d:%s(): ", file, line, func);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
	panic("spl_panic");
}

void
spl_dumpstack(void)
{
	/* Stack dump not yet implemented on OSv */
}

/*
 * assfail/assfail3 - provided by opensolaris_cmn_err.c, not duplicated here.
 */

/*
 * delay - sleep for a number of clock ticks.
 * hz is defined as (1000L) by netport.h (included via zfs_context.h).
 */
void
delay(clock_t ticks)
{
	/* Convert ticks to microseconds and sleep */
	if (ticks > 0) {
		struct timespec ts;
		uint64_t usec = (uint64_t)ticks * 1000000 / hz;
		ts.tv_sec = usec / 1000000;
		ts.tv_nsec = (usec % 1000000) * 1000;
		nanosleep(&ts, NULL);
	}
}

/*
 * zfs_debug_level - now defined in sysctl_os.c, not duplicated here.
 */

/*
 * abd_alloc_from_pages - Direct I/O page-based ABD allocation.
 * Not supported on OSv (no VM pages). Panics if called.
 */
struct abd *
abd_alloc_from_pages(vm_page_t *pages, unsigned long offset, uint64_t size)
{
	(void) pages;
	(void) offset;
	(void) size;
	panic("abd_alloc_from_pages: Direct I/O not supported on OSv");
	return (NULL);
}

/*
 * kmem_scnprintf - snprintf that returns characters written (not would-write).
 */
int
kmem_scnprintf(char *restrict str, size_t size,
    const char *restrict fmt, ...)
{
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(str, size, fmt, ap);
	va_end(ap);

	if (n >= (int)size)
		n = (int)size - 1;
	if (n < 0)
		n = 0;
	return (n);
}
