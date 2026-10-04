// Copyright (C) 2026 Greg Burd
// BSD license; see LICENSE in the top-level directory.
// Adapted from the reviewed tst-yarrow-reseed fixture; actual crypto is linked.
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cerrno>
#include <fcntl.h>
#include <mutex>
#include <thread>
#define __OSV__
#define _KERNEL
#define RANDOM_YARROW
#define MTX_DEF 0
#define PUSER 0
#define PCATCH 0
// KERNEL_HEADERS
struct mtx { std::mutex lock; bool destroyed = false; };
static void mtx_init(mtx* m, const char*, void*, int) { m->destroyed = false; }
[[maybe_unused]] static void mtx_destroy(mtx* m) { m->destroyed = true; }
static thread_local bool hold_read, observe_event;
static std::atomic<bool> read_held{false}, release_read{false}, event_lock_attempted{false};
static void mtx_lock(mtx* m) {
    if (observe_event) event_lock_attempted = true;
    assert(!m->destroyed && "Yarrow mutex destroyed while exported API remains callable");
    m->lock.lock();
    if (hold_read) {
        read_held = true;
        while (!release_read.load()) std::this_thread::yield();
    }
}
static void mtx_unlock(mtx* m) { m->lock.unlock(); }
static struct { int seeded; } random_context;
static void wakeup(void*) {}
static void debug(const char*) {}
[[maybe_unused, noreturn]] static void panic(const char* reason) {
    fprintf(stderr, "PANIC: %s\n", reason);
    std::abort();
}
static int msleep(void*, mtx*, int, const char*, int) { assert(false); return 0; }
[[maybe_unused]] static int random_harvestq_flush() { return ENXIO; }
// KERNEL_CODE
int main(int argc, char** argv) {
    assert(argc == 2);
    random_yarrow_init_alg();
    if (!strcmp(argv[1], "reinit")) {
        random_yarrow_init_alg();
        assert(false && "Yarrow reinitialization accepted");
    } else if (!strcmp(argv[1], "held")) {
        std::thread reader([] {
            hold_read = true;
            char bytes[32];
            assert(random_yarrow_read(bytes, sizeof(bytes)) == sizeof(bytes));
        });
        while (!read_held.load()) std::this_thread::yield();
        // Actual read is inside the critical section, not merely started.
        random_yarrow_deinit_alg();
        assert(!random_reseed_mtx.destroyed && "deinit destroyed mutex during active read");
        release_read = true;
        reader.join();
    } else if (!strcmp(argv[1], "master-event-contract")) {
        struct harvest event(42, "x", 1, 0, RANDOM_INTERRUPT);
        mtx_lock(&random_reseed_mtx);
        std::atomic<bool> done{false};
        std::thread worker([&] {
            observe_event = true;
            random_process_event(&event);
            done = true;
        });
        while (!event_lock_attempted.load() && !done.load()) std::this_thread::yield();
        bool escaped = done.load();
        mtx_unlock(&random_reseed_mtx);
        worker.join();
        assert(escaped && "port changed master's event locking contract");
        puts("LIMITATION: master and port event updates bypass output mutex");
    } else if (!strcmp(argv[1], "stopped")) {
        random_yarrow_reseed();
        char bytes[32];
        assert(random_yarrow_read(bytes, sizeof(bytes)) == sizeof(bytes));
        auto before = random_state;
        randomdev_flush_reseed();
        assert(memcmp(&before, &random_state, sizeof(before)) == 0 && "stopped adaptor rekeyed");
    } else {
        assert(!strcmp(argv[1], "retained"));
        // Real deinit must not destroy a lock still used by exported output.
        // Master does NOT serialize random_process_event with read/reseed.
        random_yarrow_deinit_alg();
        assert(randomdev_block(O_NONBLOCK) == EWOULDBLOCK);
        std::thread reader([] {
            for (int i = 0; i < 100; ++i) {
                char bytes[32];
                assert(random_yarrow_read(bytes, sizeof(bytes)) == sizeof(bytes));
            }
        });
        for (int i = 0; i < 100; ++i) random_yarrow_reseed();
        reader.join();
        struct harvest event(42, "x", 1, 0, RANDOM_INTERRUPT);
        random_process_event(&event); // sequential: no unsupported race claim
    }
    puts("PASS: actual master Yarrow lifecycle control");
}
