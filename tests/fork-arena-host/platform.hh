// Copyright (C) 2026 Greg Burd
// SPDX-License-Identifier: BSD-2-Clause
#define CONF_fork 1
#include <atomic>
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cstdlib>
#include <cassert>
#include <cstdio>
#include <algorithm>
#include <mutex>
#include <thread>
#include <vector>
#include <sys/mman.h>
#include <unistd.h>

namespace host {
thread_local int tid = 0;
thread_local bool preemptable = true, irq = true;
std::atomic<int> mode{0}, maps{0};
std::atomic<bool> published_owner{false}, reader_done{false};
std::atomic<bool> first_mapping{false}, contender{false}, first_done{false};
std::atomic<bool> read_head{false}, aba_done{false};
std::atomic<bool> carve_paused{false}, grown{false}, end_visible{false}, freed{false};
bool fail_map = false;
void wait(std::atomic<bool>& flag) {
    while (!flag.load()) std::this_thread::yield();
}
void published() {
    if (mode == 1 && tid == 1) {
        published_owner = true;
        wait(reader_done);
    }
}
void carve_read() {
    if (mode == 4 && tid == 1 && !carve_paused.exchange(true)) wait(grown);
}
void end_published() {
    if (mode == 5 && tid == 1) { end_visible = true; wait(freed); }
}
void pop_read() {
    if (mode == 3 && tid == 1 && !read_head.exchange(true)) wait(aba_done);
}
}
namespace fork_arena { extern volatile __thread unsigned force_kernel_heap; }
struct spinlock {
    std::mutex m;
    void lock() { m.lock(); }
    void unlock() { m.unlock(); }
};
struct mutex {
    std::mutex m;
    void lock() {
        // Kernel waiter allocation must not route back into the arena.
        assert(fork_arena::force_kernel_heap);
        assert(host::preemptable && host::irq);
        if (host::mode == 2 && host::tid == 2) host::contender = true;
        m.lock();
    }
    void unlock() { m.unlock(); }
};
#define JOIN_(a,b) a##b
#define JOIN(a,b) JOIN_(a,b)
#define SCOPE_LOCK(x) std::lock_guard<decltype(x)> JOIN(guard_,__COUNTER__)(x)
namespace sched { bool preemptable() { return host::preemptable; } }
namespace arch { bool irq_enabled() { return host::irq; } }
namespace mmu {
int identity;
thread_local void* current_as = &identity;
void* current_address_space() { return current_as; }
constexpr int mmap_fixed=1, mmap_populate=2, perm_rw=3;
void* map_anon(const void* want, size_t size, int flags, int perm) {
    assert(flags == (mmap_fixed | mmap_populate) && perm == perm_rw);
    assert(host::preemptable && host::irq);
    if (host::mode == 2) {
        if (host::tid == 1) {
            host::first_mapping = true;
            host::wait(host::contender);
        } else if (host::tid == 2) {
            host::contender = true;
            host::wait(host::first_done);
        }
    }
    ++host::maps;
    if (host::fail_map) { host::fail_map = false; return nullptr; }
    void* p = ::mmap(const_cast<void*>(want), size, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    assert(p != MAP_FAILED);
    return p;
}
void munmap(void* p, size_t n) { assert(::munmap(p, n) == 0); }
}
void debugf(const char*, ...) {}
void debug_early_u64(const char*, unsigned long long) {}
template<class T> T align_up(T x, T a) { return (x+a-1)&~(a-1); }
