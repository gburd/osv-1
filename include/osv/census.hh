/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#ifndef OSV_CENSUS_HH
#define OSV_CENSUS_HH

// Diagnosis-only timers for the memory census: time spent in a few stages of
// reaping a fork child, and in TLB flushes, printed by memory::census_start().

#include <atomic>
#include <osv/clock.hh>

namespace sched {

enum census_stage {
    cs_cleanup_misc,    // child_exited, unregister_pid, signal actions
    cs_fds,             // release_inherited_fds
    cs_destroy_as,      // destroy_address_space, all of it
    cs_pt_teardown,     // its page-table walk and frees
    cs_dispose,         // thread::dispose of the child thread
    cs_stack_free,      // a thread's stack deleter, on the reaper
    cs_flush_reaper,    // TLB flushes issued by the reaper
    cs_flush_all,       // TLB flushes issued by anyone
    cs_flush_cow,       // ...of which by the COW write-fault handler
    cs_flush_pagecache, // ...of which by the page cache
    cs_flush_operate,   // ...of which by operate_range (munmap, mprotect, ...)
    cs_count
};
extern std::atomic<long> census_ns[cs_count + 1], census_n[cs_count + 1];  // [cs_count]: not counted
extern __thread bool census_in_reap;

struct census_timer {
    census_stage s;
    osv::clock::uptime::time_point t0 = osv::clock::uptime::now();
    explicit census_timer(census_stage stage) : s(stage) {}
    ~census_timer()
    {
        census_ns[s].fetch_add((osv::clock::uptime::now() - t0).count(), std::memory_order_relaxed);
        census_n[s].fetch_add(1, std::memory_order_relaxed);
    }
};

}

#endif
