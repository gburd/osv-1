// Copyright (C) 2026 Greg Burd. BSD license; see LICENSE.
#include <algorithm>
#include <atomic>
#include <cassert>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <shared_mutex>
#include <thread>
#include <type_traits>
#include <sys/types.h>
#include "queue.h"
#define __OSV__
#define _KERNEL
#define __FBSDID(x)
#define KASSERT(x,y) assert(x)
#define MIN(a,b) std::min(a,b)
#define debugf(...) ((void)0)
// HEADERS
using event_proc_f = void(*)(struct harvest*);
struct random_hardware_source { const char* ident; esource source; int(*read)(void*,int); };
struct live_entropy_sources {
    LIST_ENTRY(live_entropy_sources) entries;
    random_hardware_source* rsource;
};
static std::mutex gate;
static std::condition_variable cv;
static bool callback_entered, release_callback, lock_attempted;
static thread_local bool observe_lock;
static std::atomic<unsigned> received{0};
struct sx { std::shared_mutex lock; bool destroyed = false; };
[[maybe_unused]] static void sx_init(sx*, const char*) {
    assert(false && "registry reset after static construction/source registration");
}
[[maybe_unused]] static void sx_destroy(sx* s) { s->destroyed = true; }
static void sx_slock(sx* s) {
    assert(!s->destroyed && "registry lock destroyed while exported feed remains callable");
    s->lock.lock_shared();
}
static void sx_sunlock(sx* s) { s->lock.unlock_shared(); }
static void attempted() {
    if (observe_lock) {
        std::lock_guard<std::mutex> g(gate);
        lock_attempted = true; cv.notify_all();
    }
}
static void sx_xlock(sx* s) { attempted(); assert(!s->destroyed); s->lock.lock(); }
static void sx_xunlock(sx* s) { s->lock.unlock(); }
static uint64_t get_cyclecount() { return 42; }
// REGISTRY
struct irq_save_lock_type { void lock() {} void unlock() {} };
struct spinlock {
    std::mutex lock_;
    void lock() { attempted(); lock_.lock(); }
    void unlock() { lock_.unlock(); }
};
static spinlock harvest_registration_lock;
static void (*reap_func)(uint64_t, const void*, unsigned, unsigned, esource);
static int phony(void*, int) { return 0; }
static auto read_random_phony = phony;
static int (*read_func)(void*, int) = phony;
static int warned;
// REGISTRATION
[[maybe_unused, noreturn]] static void panic(const char* reason) {
    fprintf(stderr, "PANIC: %s\n", reason); std::abort();
}
static struct { int(*read)(void*,int); } random_context{phony};
static void random_harvestq_init(event_proc_f) {}
void random_process_event(struct harvest*) {}
static void random_harvestq_internal(uint64_t, const void*, unsigned, unsigned, esource) {}
// ADAPTOR
static void callback_gate() {
    std::unique_lock<std::mutex> g(gate);
    callback_entered = true; cv.notify_all();
    cv.wait(g, [] { return release_callback; });
}
static int read_source(void* out, int n) { callback_gate(); memset(out, 1, n); return n; }
static void process(struct harvest*) { ++received; }
static void reaper(uint64_t, const void*, unsigned, unsigned, esource) { callback_gate(); ++received; }
int main(int argc, char** argv) {
    assert(argc == 2);
    if (!strcmp(argv[1], "reinit")) {
        randomdev_init(); randomdev_init();
        assert(false && "adaptor reinitialization accepted");
    } else if (!strcmp(argv[1], "registry-init")) {
        random_hardware_source src{"test", RANDOM_INTERRUPT, read_source};
        live_entropy_source_register(&src);
        live_entropy_sources_init(nullptr);
        live_entropy_source_deregister(&src);
        assert(live_entropy_sources_empty());
    } else if (!strcmp(argv[1], "registry-stop")) {
        live_entropy_sources_deinit(nullptr);
        live_entropy_sources_feed(1, process);
    } else {
        bool registration = !strcmp(argv[1], "registration");
        assert(registration || !strcmp(argv[1], "deregister"));
        random_hardware_source src{"test", RANDOM_INTERRUPT, read_source};
        if (registration) randomdev_init_harvester(reaper, phony);
        else live_entropy_source_register(&src);
        std::thread producer([&] {
            if (registration) random_harvest("x", 1, 0, RANDOM_INTERRUPT);
            else live_entropy_sources_feed(1, process);
        });
        {
            std::unique_lock<std::mutex> g(gate);
            cv.wait(g, [] { return callback_entered; });
        }
        std::atomic<bool> removed{false};
        std::thread remover([&] {
            observe_lock = true;
            if (registration) randomdev_deinit_harvester();
            else live_entropy_source_deregister(&src);
            std::lock_guard<std::mutex> g(gate);
            removed = true; cv.notify_all();
        });
        {
            std::unique_lock<std::mutex> g(gate);
            cv.wait(g, [&] { return lock_attempted || removed.load(); });
            assert(!removed && "deregister returned while callback active");
            release_callback = true; cv.notify_all();
        }
        producer.join(); remover.join();
        assert(received == 1);
        if (registration) random_harvest("x", 1, 0, RANDOM_INTERRUPT);
        else { assert(live_entropy_sources_empty()); live_entropy_sources_feed(1, process); }
        assert(received == 1);
    }
    puts("PASS: actual registry/registration lifecycle");
}
