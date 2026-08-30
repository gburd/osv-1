/*
 * Copyright (C) 2014 Huawei Technologies Duesseldorf GmbH
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#ifndef ARCH_TLS_HH
#define ARCH_TLS_HH

/* Thread pointer points to the element containing the dtv pointer.
 * This is trying to match the data structures in
 * glibc-2.19/ports/sysdeps/aarch64/nptl/tls.h
 */

/* the structure (roughly) corresponds to the tcbhead_t in glibc */
struct thread_control_block {
    void *tls_base; // Address of the per-thread static TLS block (kernel, pie, etc)
    void *dtv;      // Address of the DTV (Dynamic Thread Vector)
    // App-installed thread pointer (tpidr_el0) for a foreign (glibc) app that
    // manages its own TLS.  0 for a musl-on-OSv app that uses OSv per-thread
    // TLS.  A fork child reads the parent value to decide whether to re-install
    // the app tpidr_el0 (see arch/aarch64/fork.cc).  Appended at the END to
    // keep the glibc tcbhead_t-compatible offsets of the fields above intact.
    unsigned long app_tcb;
};

#endif /* ARCH_TLS_HH */
