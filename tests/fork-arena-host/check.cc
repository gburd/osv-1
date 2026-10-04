// Copyright (C) 2026 Greg Burd
// SPDX-License-Identifier: BSD-2-Clause
using namespace fork_arena;

static void setup()
{
    g_ready = true;
    g_end = arena_base;
    g_bump = arena_base;
    g_reclaim_on = 1;
    g_ovf_recycle = 1;
}

static void publication()
{
    host::mode = 1;
    void* live = nullptr;
    std::thread creator([] {
        host::tid = 1;
        assert(slot_for(mmu::current_address_space()));
    });
    host::wait(host::published_owner);
    std::thread reader([&] {
        live = alloc(32, 16);
        assert(live);
        std::memset(live, 0x5a, 32);
        host::reader_done = true;
    });
    reader.join();
    creator.join();
    auto next = alloc(32, 16);
    assert(next && next != live);
    for (unsigned i = 0; i < 32; ++i) assert(static_cast<unsigned char*>(live)[i] == 0x5a);
}

static void collision()
{
    slot_for(mmu::current_address_space());
    host::mode = 2;
    void *a = nullptr, *b = nullptr;
    std::thread first([&] {
        host::tid = 1;
        a = alloc(32, 16);
        assert(a);
        std::memset(a, 0x6b, 32);
        host::first_done = true;
    });
    host::wait(host::first_mapping);
    std::thread second([&] { host::tid = 2; b = alloc(32, 16); });
    first.join();
    second.join();
    assert(a && b && a != b);
    // Linux MAP_FIXED, like OSv evacuate(), discards the first mapping's data.
    // The old loser also unmaps it; fail on that before dereferencing.
    unsigned char resident;
    assert(::mincore(reinterpret_cast<void*>(ovf_slot_base), 4096, &resident) == 0);
    for (unsigned i = 0; i < 32; ++i) assert(static_cast<unsigned char*>(a)[i] == 0x6b);
    assert(host::maps == 1);
}

static void boundary_cas()
{
    auto fl = slot_for(mmu::current_address_space());
    assert(overflow_alloc(fl, ovf_region_sz - 64));
    host::mode = 4;
    void* slow = nullptr;
    std::thread reader([&] { host::tid = 1; slow = overflow_alloc(fl, 48); });
    host::wait(host::carve_paused);
    auto big = overflow_alloc(fl, max_alloc);
    assert(big == reinterpret_cast<void*>(ovf_slot_base + ovf_region_sz));
    memset(big, 0x29, max_alloc);
    host::grown = true;
    reader.join();
    assert(slow == reinterpret_cast<void*>(ovf_slot_base + 3 * ovf_region_sz));
    auto bytes = static_cast<unsigned char*>(big);
    for (size_t i = 0; i < max_alloc; ++i) assert(bytes[i] == 0x29);
}

static void publish_free()
{
    slot_for(mmu::current_address_space());
    host::mode = 5;
    std::thread grower([] { host::tid = 1; assert(alloc(32, 16)); });
    host::wait(host::end_visible);
    auto p = alloc(32, 16);
    assert(p);
    fork_arena::free(p);
    host::freed = true;
    grower.join();
    assert(alloc(32, 16) == p); // high-water must be visible before fast carving
}

static void boundaries()
{
    auto as = mmu::current_address_space();
    auto fl = slot_for(as);
    host::fail_map = true;
    assert(!overflow_alloc(fl, 64));
    assert(fl->ovf_mapped == 0);
    auto first = overflow_alloc(fl, 64);
    assert(first == reinterpret_cast<void*>(ovf_slot_base));
    assert(host::maps == 2);
    host::irq = false;
    assert(!overflow_alloc(fl, 64));
    assert(!overflow_alloc(fl, max_alloc));
    host::irq = true;
    host::preemptable = false;
    assert(!overflow_alloc(fl, max_alloc));
    host::preemptable = true;
    auto big = overflow_alloc(fl, max_alloc);
    assert(big == reinterpret_cast<void*>(ovf_slot_base + ovf_region_sz));
    // A large request abandons a small tail; later small allocations must not
    // reuse either the earlier live allocation or the abandoned region.
    assert(overflow_alloc(fl, 48) == reinterpret_cast<void*>(ovf_slot_base + 3 * ovf_region_sz));
    auto bytes = fl->ovf_mapped.load();
    mmu::munmap(reinterpret_cast<void*>(ovf_slot_base), bytes);
    release_as(as);
    assert(live_as_slots() == 0);
    int other_as;
    mmu::current_as = &other_as;
    auto reused = slot_for(&other_as);
    assert(reused == fl);
    assert(reused->ovf_mapped == 0);
    // Test exact last-region fit without committing the preceding 2 GiB.
    reused->ovf_mapped = ovf_window_sz - ovf_region_sz;
    auto last = overflow_alloc(reused, ovf_region_sz);
    assert(last == reinterpret_cast<void*>(ovf_slot_base + ovf_window_sz - ovf_region_sz));
    assert(!overflow_alloc(reused, 16));
    mmu::munmap(last, ovf_region_sz);
    release_as(&other_as);
    // Reusing the SAME address_space pointer also starts a new lifetime.
    assert(slot_for(&other_as) == fl);
    assert(overflow_alloc(fl, 64) == reinterpret_cast<void*>(ovf_slot_base));
}

static void threads()
{
    constexpr unsigned count = 4, each = 48;
    void* pointers[count][each]{};
    size_t sizes[count][each]{};
    std::thread workers[count];
    for (unsigned t = 0; t < count; ++t) {
        workers[t] = std::thread([&, t] {
            for (unsigned i = 0; i < each; ++i) {
                auto n = (i % 3 == 0) ? 1048576u : (i % 3 == 1 ? 47u : 10000u);
                auto p = alloc(n, 16);
                assert(p);
                pointers[t][i] = p;
                sizes[t][i] = n;
                std::memset(p, t + 1, n);
            }
        });
    }
    for (auto& w : workers) w.join();
    std::vector<uintptr_t> addresses;
    for (unsigned t = 0; t < count; ++t) {
        for (unsigned i = 0; i < each; ++i) {
            auto p = static_cast<unsigned char*>(pointers[t][i]);
            addresses.push_back(reinterpret_cast<uintptr_t>(p));
            for (size_t j = 0; j < sizes[t][i]; ++j) assert(p[j] == t + 1);
            fork_arena::free(p);
        }
    }
    std::sort(addresses.begin(), addresses.end());
    assert(std::adjacent_find(addresses.begin(), addresses.end()) == addresses.end());
    auto before = host::maps.load();
    auto recycled = alloc(47, 16);
    assert(std::binary_search(addresses.begin(), addresses.end(), reinterpret_cast<uintptr_t>(recycled)));
    assert(host::maps == before);
}

static void aba()
{
    void* b = alloc(32, 16);
    void* a = alloc(32, 16);
    fork_arena::free(b);
    fork_arena::free(a);
    host::mode = 3;
    void* slow = nullptr;
    std::thread reader([&] { host::tid = 1; slow = alloc(32, 16); });
    host::wait(host::read_head);
    assert(alloc(32, 16) == a);
    void* live = alloc(32, 16);
    assert(live == b);
    fork_arena::free(a);
    host::aba_done = true;
    reader.join();
    assert(slow == a);
    assert(alloc(32, 16) != live); // A stale pop must not republish the live B.
}

// Removing the atomic-context guard must fail without touching even an
// inaccessible arena page. Read-only free catches an in-band link write.
static void readonly_free()
{
    auto p = alloc(32, 16);
    auto page = reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(p) & ~4095ull);
    assert(::mprotect(page, 4096, PROT_READ) == 0);
    std::atomic<bool> vma_held{false}, free_done{false};
    std::thread vma_owner([&] {
        std::lock_guard<std::mutex> vma(host::vma_lock);
        vma_held = true;
        // If free writes an arena link, it faults under the VMA lock.
        fork_arena::free(p);
        free_done = true;
    });
    host::wait(vma_held);
    std::thread other([&] {
        host::wait(free_done);
        // A simultaneous mapping claimant must make forward progress too.
        std::lock_guard<std::mutex> vma(host::vma_lock);
    });
    vma_owner.join();
    other.join();
    assert(::mprotect(page, 4096, PROT_READ | PROT_WRITE) == 0);
    assert(alloc(32, 16) == p);
}

static void cache_bound()
{
    // More frees than cache slots: all must remain disjoint when allocated
    // again, including the discarded entry. Teardown must reset indices.
    std::vector<void*> ptrs(1025);
    for (auto& p : ptrs) { p = alloc(32, 16); assert(p); }
    unsigned long before, after;
    overflow_stats(nullptr, &before, nullptr, nullptr);
    for (auto p : ptrs) fork_arena::free(p);
    overflow_stats(nullptr, &after, nullptr, nullptr);
    assert(after - before == 1024 * 48); // accepted bytes only, not dropped free
    auto dropped = ptrs.back();
    for (unsigned i = 0; i < 1024; ++i) {
        auto p = alloc(32, 16);
        assert(p == ptrs[1023 - i]); // exact capacity and LIFO reuse
        assert(p != dropped);
    }
    auto fresh = alloc(32, 16);
    assert(fresh && fresh != dropped);
    ptrs.back() = fresh;
    std::sort(ptrs.begin(), ptrs.end());
    assert(std::adjacent_find(ptrs.begin(), ptrs.end()) == ptrs.end());
    for (auto p : ptrs) fork_arena::free(p);
    release_as(mmu::current_address_space());
    assert(live_as_slots() == 0);
    auto p = alloc(32, 16);
    assert(p);
    fork_arena::free(p);
    assert(alloc(32, 16) == p);
}

static void atomic_touch()
{
    auto p = alloc(32, 16);
    fork_arena::free(p);
    auto page = reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(p) & ~4095ull);
    assert(::mprotect(page, 4096, PROT_NONE) == 0);
    host::irq = false;
    assert(!alloc(32, 16));
    fork_arena::free(p); // deliberately unreadable: early bypass must not load header
    host::irq = true;
    host::preemptable = false;
    assert(!alloc(64, 16));
    fork_arena::free(p);
    host::preemptable = true;
    assert(::mprotect(page, 4096, PROT_READ | PROT_WRITE) == 0);
    assert(alloc(32, 16) == p);
}

static void recycle_stress()
{
    std::mutex live_lock;
    std::vector<void*> live;
    std::thread workers[4];
    for (unsigned t = 0; t < 4; ++t) workers[t] = std::thread([&, t] {
        for (unsigned i = 0; i < 20000; ++i) {
            auto p = alloc(32, 16);
            assert(p);
            {
                std::lock_guard<std::mutex> guard(live_lock);
                assert(std::find(live.begin(), live.end(), p) == live.end());
                live.push_back(p);
            }
            memset(p, t + 1, 32);
            std::this_thread::yield();
            for (unsigned j = 0; j < 32; ++j) assert(static_cast<unsigned char*>(p)[j] == t + 1);
            {
                std::lock_guard<std::mutex> guard(live_lock);
                live.erase(std::find(live.begin(), live.end(), p));
            }
            fork_arena::free(p);
        }
    });
    for (auto& w : workers) w.join();
    assert(live.empty());
}

// Pause inside the actual descriptor pop. Resume only after real contention
// or rival completion, never a sleep: removing pop's lock duplicates a live VA.
static void descriptor_lock()
{
    auto first = alloc(32, 16);
    auto second = alloc(32, 16);
    assert(first && second && first != second);
    fork_arena::free(second);
    fork_arena::free(first);
    host::mode = 7;
    void *a = nullptr, *b = nullptr;
    std::thread slow([&] { host::tid = 1; a = alloc(32, 16); });
    host::wait(host::descriptor_read);
    std::thread rival([&] { host::tid = 2; b = alloc(32, 16); host::rival_done = true; });
    while (!host::blocked && !host::rival_done) std::this_thread::yield();
    puts(host::blocked ? "contender observed held descriptor lock" :
                        "contender completed while descriptor read suspended");
    fflush(stdout);
    host::resume_pop = true;
    slow.join();
    rival.join();
    assert(a && b && a != b);
    assert(host::blocked);
    puts("descriptor lock: live uniqueness and actual contention PASS");
}

static void vma_order()
{
    slot_for(mmu::current_address_space());
    host::mode = 6;
    std::string maps;
    std::thread reader([&] { maps = mmu::procfs_maps(); });
    host::wait(host::vma_held);
    std::thread grower([] { assert(alloc(64, 16)); });
    reader.join();
    grower.join();
    assert(maps == "1000-2000 rw-p 00000000 00:00 0\n");
}

int main(int argc, char** argv)
{
    assert(argc == 2);
    setup();
    if (!strcmp(argv[1], "publication")) publication();
    else if (!strcmp(argv[1], "collision")) collision();
    else if (!strcmp(argv[1], "boundary-cas")) boundary_cas();
    else if (!strcmp(argv[1], "publish-free")) publish_free();
    else if (!strcmp(argv[1], "boundaries")) boundaries();
    else if (!strcmp(argv[1], "threads")) threads();
    else if (!strcmp(argv[1], "null")) assert(slot_for(nullptr) == nullptr);
    else if (!strcmp(argv[1], "vma-order")) vma_order();
    else if (!strcmp(argv[1], "descriptor-lock")) descriptor_lock();
    else if (!strcmp(argv[1], "aba")) aba();
    else if (!strcmp(argv[1], "readonly-free")) readonly_free();
    else if (!strcmp(argv[1], "atomic-touch")) atomic_touch();
    else if (!strcmp(argv[1], "cache-bound")) cache_bound();
    else if (!strcmp(argv[1], "recycle-stress")) recycle_stress();
    else return 2;
    puts("PASS");
}
