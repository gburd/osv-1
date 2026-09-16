/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * OSv leak/wedge probe (OSV_LEAK_PROBE).
 *
 * A periodic in-kernel counter dump for hunting the forked-backend churn wedge:
 * whatever counter GROWS MONOTONICALLY across sustained fork/reap churn (and
 * correlates with a throughput collapse) is the leak.  Gated entirely on the
 * env var OSV_LEAK_PROBE=<seconds>: absent/0 => the probe thread never starts,
 * so a default build is byte-for-byte unaffected at runtime.
 *
 * Every period it prints ONE line to the console (grep 'LEAKPROBE'):
 *   LEAKPROBE t=<sec> threads=<n> app=<n> child_as=<n> \
 *       mem_free_mb=<n> mem_total_mb=<n> l2_nr=<n> l2_max=<n> \
 *       reaper_pending=<n> reaped=<n> arena_bump_mb=<n> arena_as_slots=<n> \
 *       g_children=<n> g_as_pid=<n> g_pid_as=<n> g_fd_tables=<n> g_sigtables=<n>
 * and, if the guest looks wedged (many app threads all waiting), a compact
 * thread-state histogram line:
 *   LEAKPROBE_TS t=<sec> waiting=<n> running=<n> queued=<n> waking=<n> \
 *       other=<n> app_waiting=<n>
 *
 * These are the exact candidates the leak-hunt design named: OSv thread count,
 * free memory + global_l2 nr (the 26.9GiB-free-but-nr=0 wedge signature), the
 * fork bookkeeping maps (should stay flat -- measured here, not trusted), the
 * fork-arena bump (monotonic, never returned), and the reaper zombie queue.
 */

#include <osv/sched.hh>
#include <osv/mmu.hh>
#include <osv/mempool.hh>
#include <osv/debug.hh>
#include <osv/kernel_config_fork.h>
#include <cstdlib>
#include <cstdio>
#include <atomic>

#if CONF_fork
#include <osv/fork.hh>
#include <osv/fork_arena.hh>
#endif

namespace mmu {
#if CONF_fork
extern std::atomic<int> live_child_address_spaces;
#endif
}

// gfdt occupancy accessor (fs/vfs/kern_descrip.cc); C linkage, global scope.
extern "C" unsigned long leak_probe_gfdt_count(void);

namespace osv {

static void leak_probe_loop(unsigned period_sec)
{
    using namespace std::chrono;
    unsigned long t = 0;
    while (true) {
        sched::thread::sleep(seconds(period_sec));
        t += period_sec;

        // --- thread count + state histogram (single pass) ---
        unsigned nthreads = 0, napp = 0;
        unsigned st_waiting = 0, st_running = 0, st_queued = 0, st_waking = 0,
                 st_other = 0, app_waiting = 0;
        sched::with_all_threads([&](sched::thread &th) {
            nthreads++;
            bool app = th.is_app();
            if (app) napp++;
            auto s = th.get_status();
            switch (s) {
            case sched::thread::status::waiting:
                st_waiting++; if (app) app_waiting++; break;
            case sched::thread::status::running:
                st_running++; break;
            case sched::thread::status::queued:
                st_queued++; break;
            case sched::thread::status::waking:
            case sched::thread::status::sending_lock:
                st_waking++; break;
            default:
                st_other++; break;
            }
        });

        // --- memory ---
        unsigned long mem_free_mb  = memory::stats::free()  >> 20;
        unsigned long mem_total_mb = memory::stats::total() >> 20;
        memory::stats::pool_stats l2{};
        memory::stats::get_global_l2_stats(l2);

        // --- fork bookkeeping ---
        int child_as = 0;
        unsigned long arena_bump = 0, arena_slots = 0;
        unsigned long gc = 0, gap = 0, gpa = 0, gfd = 0, gsg = 0;
        unsigned long child_opened = 0, owner_released = 0, gfdt = 0;
        long reaper_pending = 0, reaped = 0;
        sched::leak_probe_reaper_stats(&reaper_pending, &reaped);
        { gfdt = leak_probe_gfdt_count(); }
#if CONF_fork
        child_as = mmu::live_child_address_spaces.load(std::memory_order_relaxed);
        fork_arena::leak_probe_stats(&arena_bump, &arena_slots);
        osv::fork::leak_probe_map_sizes(&gc, &gap, &gpa, &gfd, &gsg);
        osv::fork::leak_probe_fd_stats(&child_opened, &owner_released);
#endif
        // arena_bump is a monotonic global VA cursor; past arena_size (512 MiB)
        // it just runs away (alloc returns nullptr), so cap the reported value.
        unsigned long arena_cap_mb = 512;
        unsigned long arena_used_mb = (arena_bump >> 20);
        if (arena_used_mb > arena_cap_mb) arena_used_mb = arena_cap_mb;

        printf("LEAKPROBE t=%lu threads=%u app=%u child_as=%d "
               "mem_free_mb=%lu mem_total_mb=%lu l2_nr=%lu l2_max=%lu "
               "reaper_pending=%ld reaped=%ld gfdt=%lu child_opened=%lu owner_released=%lu "
               "arena_used_mb=%lu arena_as_slots=%lu "
               "g_children=%lu g_as_pid=%lu g_pid_as=%lu g_inherited=%lu g_sigtables=%lu\n",
               t, nthreads, napp, child_as,
               mem_free_mb, mem_total_mb, (unsigned long)l2._nr, (unsigned long)l2._max,
               reaper_pending, reaped, gfdt, child_opened, owner_released,
               arena_used_mb, arena_slots,
               gc, gap, gpa, gfd, gsg);
        printf("LEAKPROBE_TS t=%lu waiting=%u running=%u queued=%u waking=%u "
               "other=%u app_waiting=%u\n",
               t, st_waiting, st_running, st_queued, st_waking, st_other, app_waiting);
    }
}

void maybe_start_leak_probe()
{
    const char *e = getenv("OSV_LEAK_PROBE");
    if (!e || !e[0]) {
        return;
    }
    unsigned period = (unsigned)strtoul(e, nullptr, 10);
    if (period == 0) {
        return;
    }
    printf("LEAKPROBE armed: period=%us\n", period);
    // Detached kernel thread (AS0); lives for the boot.
    auto *t = sched::thread::make([period] { leak_probe_loop(period); },
                                  sched::thread::attr().detached().name("leak-probe"));
    t->start();
}

} // namespace osv

// Global-namespace boot hook (called from sched::init_detached_threads_reaper).
void maybe_start_leak_probe() { osv::maybe_start_leak_probe(); }
