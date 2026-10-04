/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

// Guest integration smoke test. Needs CONF_fork=1, reclaim/recycling enabled,
// >= 1.5 GiB RAM and preferably >= 2 CPUs. The deterministic schedules live in
// fork-arena-host/; this test exercises the real malloc/MMU/scheduler path.
#include <osv/kernel_config_fork.h>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <thread>
#include <mutex>
#include <atomic>
#include <algorithm>
#include <iterator>
#include <unistd.h>
#include <sys/wait.h>

#if CONF_fork
#include <osv/fork_arena.hh>
#include <osv/sched.hh>
#include <osv/irqlock.hh>

// Both global and overflow pages are inherited read-only after fork. Exercise
// actual kernel COW, not a host lock/mapping substitute.
static void cow_atomic()
{
    auto p = fork_arena::alloc(32, 16);
    auto recycled = fork_arena::alloc(48, 16);
    assert(p && recycled);
    memset(p, 0x39, 32);
    fork_arena::free(recycled);
    auto pid = fork();
    assert(pid >= 0);
    if (!pid) {
        // Free an inherited read-only allocation, then recycle in this AS.
        fork_arena::free(p);
        auto q = fork_arena::alloc(32, 16);
        if (!q) _exit(2);
        memset(q, 0x61, 32);
        fork_arena::free(q);
        _exit(0);
    }
    bool irq_ok, preempt_ok;
    {
        irq_save_lock_type irq;
        irq.lock();
        auto a = fork_arena::alloc(32, 16); // fresh class
        auto b = fork_arena::alloc(48, 16); // recycled class
        fork_arena::free(p);               // no header/link touch
        irq_ok = !a && !b;
        irq.unlock();
    }
    sched::preempt_disable();
    auto a = fork_arena::alloc(32, 16);
    auto b = fork_arena::alloc(48, 16);
    fork_arena::free(p);
    preempt_ok = !a && !b;
    sched::preempt_enable();
    assert(irq_ok && preempt_ok);
    int status;
    assert(waitpid(pid, &status, 0) == pid);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    for (unsigned j = 0; j < 32; ++j) assert(static_cast<unsigned char*>(p)[j] == 0x39);
    fork_arena::free(p); // normal-context free of parent's inherited COW page
    auto q = fork_arena::alloc(32, 16);
    assert(q == p);
    memset(q, 0x42, 32); // real parent COW write after recycle lock released
    fork_arena::free(q);
    puts("PASS: parent/child COW free and IRQ/preempt arena bypass");
}

static void concurrent_recycle()
{
    std::mutex lock;
    void* live[4]{};
    std::thread workers[4];
    for (unsigned t = 0; t < 4; ++t) workers[t] = std::thread([&, t] {
        for (unsigned i = 0; i < 5000; ++i) {
            auto p = malloc(32);
            assert(p && fork_arena::contains(p));
            {
                std::lock_guard<std::mutex> guard(lock);
                for (auto q : live) assert(p != q);
                live[t] = p;
            }
            memset(p, t + 1, 32);
            std::this_thread::yield();
            for (unsigned j = 0; j < 32; ++j) assert(static_cast<unsigned char*>(p)[j] == t + 1);
            {
                std::lock_guard<std::mutex> guard(lock);
                live[t] = nullptr;
            }
            free(p);
        }
    });
    for (auto& w : workers) w.join();
    puts("PASS: concurrent recycle live uniqueness/payload/progress");
}

int main()
{
    cow_atomic();
    concurrent_recycle();
    // Keep allocations LIVE: freeing these would refill the size-class lists
    // instead of forcing overflow. The maximum number covers a fresh arena.
    constexpr size_t large = fork_arena::max_alloc - 16;
    constexpr unsigned count = fork_arena::arena_size / fork_arena::max_alloc + 1;
    void* fill[count]{};
    unsigned used = 0;
    constexpr uintptr_t overflow = 97ull << 39;
    while (used < count) {
        auto p = malloc(large);
        assert(p && fork_arena::contains(p)); // no identity fallback false green
        fill[used++] = p;
        if (reinterpret_cast<uintptr_t>(p) >= overflow) break;
    }
    assert(reinterpret_cast<uintptr_t>(fill[used - 1]) >= overflow);
    cow_atomic();
    concurrent_recycle();
    constexpr unsigned workers = 4, allocations = 16;
    void* live[workers * allocations]{};
    size_t sizes[workers * allocations]{};
    std::atomic<unsigned> arrived{0};
    std::atomic<bool> start{false};
    std::thread threads[workers];
    for (unsigned t = 0; t < workers; ++t) {
        threads[t] = std::thread([&, t] {
            ++arrived;
            while (!start.load()) std::this_thread::yield();
            for (unsigned i = 0; i < allocations; ++i) {
                auto index = t * allocations + i;
                sizes[index] = i % 2 ? 47 : 1048576;
                auto p = malloc(sizes[index]);
                assert(p && fork_arena::contains(p));
                if (sizes[index] == 1048576) {
                    assert(reinterpret_cast<uintptr_t>(p) >= overflow);
                }
                live[index] = p;
                memset(p, index + 1, sizes[index]);
            }
        });
    }
    while (arrived.load() != workers) std::this_thread::yield();
    start = true;
    for (auto& t : threads) t.join();
    uintptr_t addresses[workers * allocations];
    for (unsigned i = 0; i < workers * allocations; ++i) {
        addresses[i] = reinterpret_cast<uintptr_t>(live[i]);
        auto p = static_cast<unsigned char*>(live[i]);
        for (size_t j = 0; j < sizes[i]; ++j) assert(p[j] == i + 1);
    }
    std::sort(std::begin(addresses), std::end(addresses));
    assert(std::adjacent_find(std::begin(addresses), std::end(addresses)) == std::end(addresses));
    // Sequential recycling supplements the concurrent checks above.
    for (auto p : live) free(p);
    for (unsigned i = 0; i < workers * allocations; ++i) {
        live[i] = malloc(sizes[i]);
        assert(live[i] && fork_arena::contains(live[i]));
        memset(live[i], 0x71, sizes[i]);
    }
    for (unsigned round = 0; round < 3; ++round) {
        auto pid = fork();
        assert(pid >= 0);
        if (!pid) {
            auto p = malloc(1048576);
            if (!p || !fork_arena::contains(p)) _exit(1);
            memset(p, 0x42, 1048576);
            free(p);
            _exit(0);
        }
        int status;
        assert(waitpid(pid, &status, 0) == pid);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    for (unsigned i = 0; i < workers * allocations; ++i) {
        auto p = static_cast<unsigned char*>(live[i]);
        for (size_t j = 0; j < sizes[i]; ++j) assert(p[j] == 0x71);
        free(p);
    }
    for (unsigned i = 0; i < used; ++i) free(fill[i]);
    puts("PASS: overflow uniqueness, persistence, recycling and child teardown");
}
#else
int main()
{
    puts("SKIP: requires CONF_fork=1");
}
#endif
