/*
 * Copyright (C) 2014 Huawei Technologies Duesseldorf GmbH
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#ifndef _INTERNAL_ATOMIC_H
#define _INTERNAL_ATOMIC_H

#include <stdint.h>

// Self-contained (like arch/x64/atomic.h): do NOT pull in <machine/atomic.h>
// or the BSD opensolaris <sys/types.h>.  On aarch64 those are absent / collide
// (machine/atomic.h does not exist here, and the BSD types.h redefines
// zoneid_t/boolean_t/... conflicting with the system headers when this atomic.h
// is included by the ZFS userspace tools' libspl).  a_fetch_add uses the GCC
// atomic builtin instead of FreeBSD's atomic_fetchadd_int.

static inline int a_ctz_64(register uint64_t x)
{
	register uint64_t r;
	__asm__ __volatile__ ("rbit %0, %0; clz %1, %0" : "+r"(x), "=r"(r));
	return r;
}

static inline int a_ctz_l(unsigned long x)
{
	return a_ctz_64(x);
}

static inline int a_fetch_add(volatile int *x, int v)
{
    // Returns the PRIOR value (FreeBSD atomic_fetchadd_int semantics).
    return __atomic_fetch_add(x, v, __ATOMIC_SEQ_CST);
}

static inline void a_crash()
{
    __asm__ __volatile__( "1: msr daifset, #2; wfi; b 1b; " ::: "memory");
}


#endif /* _INTERNAL_ATOMIC_H */
