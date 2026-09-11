// SPDX-License-Identifier: CDDL-1.0
/*
 * OSv SPL condvar - wraps existing OSv kcondvar.h with OpenZFS extensions
 */
#ifndef _SPL_OSV_CONDVAR_H
#define	_SPL_OSV_CONDVAR_H

/* The OSv compat layer uses kcondvar.h for condvar definitions */
#include <sys/kcondvar.h>
/* Need hrtime_t and gethrtime() for cv_timedwait_hires below */
#include <sys/time.h>
/* BENCH ONLY: getenv()/printf() for the OSV_ZFS_HIRES_CV A/B switch. */
#include <stdlib.h>
#include <stdio.h>

/*
 * OpenZFS expects these additional condvar variants.
 * On OSv, they all map to the basic cv_timedwait or cv_wait.
 */
#ifndef cv_timedwait_io
#define	cv_timedwait_io		cv_timedwait
#endif
#ifndef cv_timedwait_idle
#define	cv_timedwait_idle	cv_timedwait
#endif
#ifndef cv_timedwait_sig
#define	cv_timedwait_sig	cv_timedwait
#endif
#ifndef cv_timedwait_sig_io
#define	cv_timedwait_sig_io	cv_timedwait
#endif
#ifndef cv_wait_io
#define	cv_wait_io		cv_wait
#endif
#ifndef cv_wait_io_sig
#define	cv_wait_io_sig		cv_wait
#endif
#ifndef cv_wait_idle
#define	cv_wait_idle		cv_wait
#endif
#ifndef cv_wait_sig
#define	cv_wait_sig		cv_wait
#endif

/*
 * High-resolution condvar wait.
 *
 * NOTE: We don't declare hz or gethrtime here because they may already
 * be defined as macros (hz) or static inline functions (gethrtime) by
 * the time this header is included. Instead, we reference them directly.
 */
static inline int
cv_timedwait_hires(kcondvar_t *cvp, mutex_t *mp, long long tim,
    long long res __attribute__((unused)), int flag)
{
	long long delta_ns = tim;

	/*
	 * With CALLOUT_FLAG_ABSOLUTE, `tim` is an absolute deadline on the
	 * same clock the caller read via gethrtime(), so derive the remaining
	 * delay from gethrtime() as well rather than from any other clock.
	 */
	if (flag != 0) {
		delta_ns = tim - (long long)gethrtime();
	}
	if (delta_ns <= 0) {
		return (-1);
	}

	/*
	 * BENCH ONLY, not part of the upstream change: OSV_ZFS_HIRES_CV=0
	 * reproduces the old tick-converting behaviour so the same binary can
	 * serve both arms of an A/B.  Default is the fixed path.
	 */
	{
		static int ab = -1;
		if (ab < 0) {
			const char *e = getenv("OSV_ZFS_HIRES_CV");
			ab = (!e || !e[0]) ? 1 : (e[0] != '0');
			/* proof of binding, so a dropped flag cannot read as "no effect" */
			printf("ZFSFLAG OSV_ZFS_HIRES_CV=%d (%s)\n", ab,
			    e ? "set" : "unset, default");
		}
		if (!ab) {
			long long t = tim;
			if (flag == 0)
				t += gethrtime();
			return (cv_timedwait(cvp, mp,
			    (clock_t)(t / (1000000000LL / hz))));
		}
	}

	/*
	 * Wait the true nanosecond delay.  Converting to hz-granular ticks
	 * would round every sub-millisecond delay down to zero: the ZIL sizes
	 * its commit-batch window at ~10% of the last log-write latency
	 * (zfs_commit_timeout_pct), i.e. tens to hundreds of microseconds, so
	 * on a 1000 Hz tick grid the waiter would never wait, never accumulate
	 * a second itx, and every commit would pay its own log write and
	 * device cache flush instead of coalescing with its peers.
	 */
	return (osv_cv_timedwait_ns(cvp, mp, delta_ns));
}

#define	cv_timedwait_sig_hires		cv_timedwait_hires
#define	cv_timedwait_io_hires		cv_timedwait_hires
#define	cv_timedwait_idle_hires		cv_timedwait_hires

#endif /* _SPL_OSV_CONDVAR_H */
