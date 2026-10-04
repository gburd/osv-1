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
    assert(overflow_alloc(fl, 64) == reinterpret_cast<void*>(ovf_slot_base + 64));
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
    assert(alloc(32, 16) != live); // Known independent Treiber ABA, NOT fixed.
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
    else if (!strcmp(argv[1], "aba")) aba();
    else return 2;
    puts("PASS");
}
