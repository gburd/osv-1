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
#include <atomic>
#include <algorithm>
#include <iterator>
#include <unistd.h>
#include <sys/wait.h>

#if CONF_fork
#include <osv/fork_arena.hh>

int main()
{
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
    // Sequential free/reallocate tests recycling without purporting to cover
    // the separate, still-open concurrent Treiber freelist ABA defect.
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
