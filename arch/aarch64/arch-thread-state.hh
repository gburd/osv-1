/*
 * Copyright (C) 2014 Huawei Technologies Duesseldorf GmbH
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#ifndef ARCH_THREAD_STATE_HH_
#define ARCH_THREAD_STATE_HH_

struct thread_state {
    void* fp;
    void* thread;

    void* sp;
    void* pc;
    void* tcb;

    void* exception_sp; //SP_EL0
    u64 stack_selector; //1 - selects SP_ELx (default), 0 - selects SP_EL0 (exceptions)
    // fork COW: TTBR0_EL1 value (phys root of this thread's address space).  Set
    // by cpu_schedule_next_thread(); sched.S loads it at the context switch when
    // it differs from the currently-installed TTBR0 (a forked child runs on its
    // own cloned page-table root).  0 for the very first threads before fork is
    // active (treated as "no explicit switch" -> the boot/AS0 root stays).
    u64 ttbr0;
};

#endif /* ARCH_THREAD_STATE_HH_ */
