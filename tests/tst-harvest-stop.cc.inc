// Copyright (C) 2026 Greg Burd. BSD license; see LICENSE.
#include <atomic>
#include <cassert>
#include <cerrno>
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
static std::mutex gate;
static std::condition_variable cv;
static bool at_feed, allow_feed, entered, release_producer, admission_attempted;
static bool at_pause, allow_pause, worker_done, stop_wait, stop_done;
static unsigned processed;
static thread_local bool observe_admission;
struct np_spinlock {
    std::mutex m;
    void lock() {
        if (observe_admission) {
            std::lock_guard<std::mutex> lock(gate);
            admission_attempted = true; cv.notify_all();
        }
        m.lock();
    }
    void unlock() { m.unlock(); }
};
struct irq_save_lock_type { void lock() {} void unlock() {} };
static int hz = 100;
template<class T, unsigned N> class unordered_ring_mpsc {
    std::vector<T> events;
public:
    template<class... A> bool emplace(A&&...) {
        std::unique_lock<std::mutex> lock(gate);
        entered = true; cv.notify_all();
        cv.wait(lock, [] { return release_producer; });
        events.emplace_back(); return true;
    }
    std::vector<T> drain() {
        std::lock_guard<std::mutex> lock(gate);
        std::vector<T> out; out.swap(events); return out;
    }
};
static void live_entropy_sources_init(void*) {}
static void live_entropy_sources_feed(int, event_proc_f) {
    std::unique_lock<std::mutex> lock(gate);
    if (!at_feed) {
        at_feed = true; cv.notify_all();
        cv.wait(lock, [] { return allow_feed; });
    }
}
static void bsd_pause(const char* name, int) {
    std::unique_lock<std::mutex> lock(gate);
    if (!strcmp(name, "harvest exit")) {
        stop_wait = true; cv.notify_all();
        cv.wait(lock, [] { return worker_done; });
    } else {
        at_pause = true; cv.notify_all();
        cv.wait(lock, [] { return allow_pause; });
    }
}
static int kproc_create(void(*)(void*), void*, proc**, int, int, const char*) { return 0; }
[[noreturn]] static void panic(const char*) { std::abort(); }
static void kthread_exit() {
    std::lock_guard<std::mutex> lock(gate);
    worker_done = true; cv.notify_all();
}
// KERNEL_CODE
int main() {
    random_harvestq_init(nullptr);
    std::thread worker([] { random_kthread(reinterpret_cast<void*>(+[](harvest*) { ++processed; })); });
    {
        std::unique_lock<std::mutex> lock(gate);
        cv.wait(lock, [] { return at_feed; }); // worker already drained
    }
    std::thread producer([] { assert(random_harvestq_try(0, "x", 1, 0, RANDOM_START)); });
    {
        std::unique_lock<std::mutex> lock(gate);
        cv.wait(lock, [] { return entered; }); // admitted but not enqueued
    }
    std::thread stopper([] {
        observe_admission = true;
        random_harvestq_deinit();
        std::lock_guard<std::mutex> lock(gate);
        stop_done = true; cv.notify_all();
    });
    {
        std::unique_lock<std::mutex> lock(gate);
        cv.wait(lock, [] { return admission_attempted; });
        allow_feed = true; cv.notify_all();
        cv.wait(lock, [] { return worker_done || at_pause; });
        release_producer = true; cv.notify_all();
        cv.wait(lock, [] { return stop_wait || stop_done; });
        allow_pause = true; cv.notify_all();
    }
    producer.join(); stopper.join(); worker.join();
    assert(processed == 1 && "accepted event discarded during stop");
    puts("PASS: shutdown drains admitted producer after stop observation");
}
