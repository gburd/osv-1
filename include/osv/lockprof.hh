/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

// Lightweight lock-contention profiler.  Off by default (LOCKPROF undefined =
// zero code).  When built with -DLOCKPROF, a handful of named candidate lock
// sites are wrapped so we can answer one question under a concurrent load:
// WHICH lock do backends spend their acquire-wait time on?  Each site records
// (blocked count, total wait ns).  A background thread prints the table to the
// console periodically so a serial-log scrape names the hot lock.

#ifndef OSV_LOCKPROF_HH
#define OSV_LOCKPROF_HH

#ifdef LOCKPROF

#include <atomic>
#include <cstdint>
#include <chrono>
#include <osv/clock.hh>

namespace lockprof {

// One counter class per candidate serialization point (the ROADMAP hypothesis
// space).  Keep this list short and named.
enum site {
    SITE_REGISTRY_SHARD = 0,  // shared-anon page-provider registry shard lock (candidate 2)
    SITE_VMAS_WRITE,          // as->vmas_mutex for_write (COW write fault, candidate 1)
    SITE_VMAS_READ,           // as->vmas_mutex for_read (read fault path)
    SITE_PAGE_RANGES,         // free_page_ranges_lock (mempool global arena, candidate 3)
    SITE_MAX
};

struct counter {
    std::atomic<uint64_t> waits{0};    // times the acquire took > threshold (blocked)
    std::atomic<uint64_t> calls{0};    // total acquisitions
    std::atomic<uint64_t> wait_ns{0};  // total ns spent blocked in acquire
};

extern counter counters[SITE_MAX];
extern const char *site_name(int s);

// Registry fast/slow-path split for shared_anon_page_provider::shared_page().
// Answers: is the wall the READ path (RCU reader_find) or the INSERT path
// (reg->insert_lock, which the SITE_REGISTRY_SHARD site does NOT instrument)?
struct regsplit_counters {
    std::atomic<uint64_t> fast_hits{0};         // RCU reader_find returned a page
    std::atomic<uint64_t> fast_misses{0};       // RCU reader_find returned null -> slow path
    std::atomic<uint64_t> insert_calls{0};      // entered WITH_LOCK(reg->insert_lock)
    std::atomic<uint64_t> insert_lost_race{0};  // double-check found it (another AS inserted)
    std::atomic<uint64_t> insert_real{0};       // actually allocated+inserted a new page
    std::atomic<uint64_t> insert_lock_blocked{0};  // insert_lock acquire took > BLOCK_NS
    std::atomic<uint64_t> insert_lock_wait_ns{0};  // total ns blocked acquiring insert_lock
};
extern regsplit_counters regsplit;

// ns threshold above which an acquisition is counted as "blocked" (rather than
// an uncontended fast-path acquire that just cost a couple of atomics).
static constexpr uint64_t BLOCK_NS = 2000;  // 2us

// Time a WITH_LOCK acquisition at a named site.  Usage:
//   { LOCKPROF_ACQUIRE(lockprof::SITE_X); WITH_LOCK(the_lock) { ... } }
// The probe measures only the time to ACQUIRE (construct the guard), which is
// what contention shows up as: an uncontended acquire is a few ns, a blocked
// acquire waits for the holder.  We approximate by timing the WITH_LOCK body
// entry via a scoped helper.
class probe {
public:
    explicit probe(int s) : _site(s), _t0(osv::clock::uptime::now()) {}
    // call once the lock is actually held
    void acquired() {
        auto dt = osv::clock::uptime::now() - _t0;
        uint64_t ns = std::chrono::duration_cast<std::chrono::nanoseconds>(dt).count();
        counters[_site].calls.fetch_add(1, std::memory_order_relaxed);
        if (ns >= BLOCK_NS) {
            counters[_site].waits.fetch_add(1, std::memory_order_relaxed);
            counters[_site].wait_ns.fetch_add(ns, std::memory_order_relaxed);
        }
    }
private:
    int _site;
    osv::clock::uptime::time_point _t0;
};

void start_dumper();

} // namespace lockprof

// Measure the acquire of a WITH_LOCK at a named site.  Put this line, then the
// WITH_LOCK on the next line; the probe fires when the guard is constructed.
#define LOCKPROF_SITE(_s) lockprof::probe _lp_probe(_s)
#define LOCKPROF_ACQUIRED() _lp_probe.acquired()

#else // !LOCKPROF

#define LOCKPROF_SITE(_s) do {} while (0)
#define LOCKPROF_ACQUIRED() do {} while (0)

#endif // LOCKPROF

#endif // OSV_LOCKPROF_HH
