// Copyright (C) 2026 Greg Burd. BSD license; see LICENSE.
#include <atomic>
#include <cassert>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>
#include <cstdint>
#define __OSV__
#define __FBSDID(x)
#define KASSERT(x,y) assert(x)
#define RFHIGHPID 0
#define HARVEST_RING_SIZE 1024
using u_int = unsigned;
using u_int64_t = uint64_t;
enum esource { RANDOM_START, ENTROPYSOURCE };
struct harvest {};
using event_proc_f = void(*)(harvest*);
struct proc {};
using mutex = std::mutex;
using spinlock = std::mutex;
static std::atomic<bool> observe_admission{false};
static void admission_attempt();
struct np_spinlock {
    std::mutex m;
    void lock() { if (observe_admission) admission_attempt(); m.lock(); }
    void unlock() { m.unlock(); }
};
struct irq_save_lock_type { void lock() {} void unlock() {} };
static int hz = 100;
static std::mutex gate;
static std::condition_variable cv;
static bool entered, release_producer, destroyed, closed, pause_producer, full;
static bool admission_attempted;
static void admission_attempt() {
    std::lock_guard<std::mutex> lock(gate);
    admission_attempted = true; cv.notify_all();
}
static std::atomic<bool> deinit_done{false};
template<class T, unsigned N> class unordered_ring_mpsc {
    unsigned value = 0;
public:
    ~unordered_ring_mpsc() {
        std::lock_guard<std::mutex> lock(gate);
        destroyed = true; cv.notify_all();
    }
    template<class... A> bool emplace(A&&...) {
        std::unique_lock<std::mutex> lock(gate);
        entered = true; cv.notify_all();
        if (pause_producer) cv.wait(lock, [] { return release_producer; });
        // Member access makes late access an ASan UAF on old candidate.
        ++value;
        return !full;
    }
    std::vector<T> drain() { return {}; }
};
static void live_entropy_sources_init(void*) {}
static void live_entropy_sources_deinit(void*) {}
static void live_entropy_sources_feed(int, event_proc_f) {}
static void bsd_pause(const char* name, int) {
    if (!strcmp(name, "harvest exit")) {
        std::lock_guard<std::mutex> lock(gate);
        closed = true; cv.notify_all();
    }
    std::this_thread::yield();
}
static int kproc_create(void(*)(void*), void*, proc**, int, int, const char*) { return 0; }
[[noreturn]] static void panic(const char* reason) {
    fprintf(stderr, "PANIC: %s\n", reason);
    fflush(stderr);
    std::abort();
}
static void kthread_exit() {}
// KERNEL_CODE
int main(int argc, char** argv) {
    assert(argc == 2);
    random_harvestq_init(nullptr);
    if (!strcmp(argv[1], "reinit")) {
        random_harvestq_init(nullptr);
        assert(false && "queue reinitialization accepted");
    }
    if (!strcmp(argv[1], "producer") || !strcmp(argv[1], "full")) {
        full = !strcmp(argv[1], "full");
        pause_producer = true;
        std::thread producer([] { assert(random_harvestq_try(0, "x", 1, 0, RANDOM_START) == !full); });
        {
            std::unique_lock<std::mutex> lock(gate);
            cv.wait(lock, [] { return entered; });
        }
        // Worker already exited: deinit must still wait for admitted producer.
        exited.store(true);
        std::thread stopper([] { observe_admission = true; random_harvestq_deinit(); deinit_done = true; cv.notify_all(); });
        {
            std::unique_lock<std::mutex> lock(gate);
            // Wait for an actual rendezvous attempt OR actual reclamation,
            // never merely a request store followed by a scheduling window.
            cv.wait(lock, [] { return admission_attempted || destroyed; });
            assert(!destroyed && "ring freed with admitted producer active");
            release_producer = true; cv.notify_all();
        }
        producer.join(); stopper.join();
    } else {
        exited.store(true);
        random_harvestq_deinit();
        if (!strcmp(argv[1], "late")) {
            assert(!random_harvestq_try(0, "x", 1, 0, RANDOM_START));
        } else {
            std::thread watchdog([] {
                std::this_thread::sleep_for(std::chrono::seconds(2));
                assert(deinit_done.load() && "late flush hangs after stop");
            });
            FLUSH_CHECK
            deinit_done = true;
            watchdog.join();
        }
    }
    puts("PASS: queue producer/late admission/late flush lifetime control");
}
