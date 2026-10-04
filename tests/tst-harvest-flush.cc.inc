// Copyright (C) 2026 Greg Burd. BSD license; see LICENSE.
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <thread>
#include <vector>
#include <cstdint>
#include <string>
#include <cerrno>
#define __OSV__
#define __FBSDID(x)
#define KASSERT(x,y) assert(x)
#define RFHIGHPID 0
#define HARVEST_RING_SIZE 1024
using u_int = unsigned;
using u_int64_t = uint64_t;
enum esource { RANDOM_START, ENTROPYSOURCE };
struct harvest {
    harvest() = default;
    harvest(uint64_t, const void*, unsigned, unsigned, esource) {}
};
using event_proc_f = void(*)(harvest*);
struct proc {};
using np_spinlock = std::mutex;
struct irq_save_lock_type { void lock() {} void unlock() {} };
static int hz = 100;
static std::mutex gate;
static std::condition_variable cv;
static thread_local bool observe_stop;
static bool stop_attempted;
static std::atomic<bool> stop_done{false};
struct mutex {
    std::mutex m;
    void lock() {
        if (observe_stop) {
            std::lock_guard<std::mutex> g(gate);
            stop_attempted = true; cv.notify_all();
        }
        m.lock();
    }
    void unlock() { m.unlock(); }
};
static bool at_feed, allow_feed, at_sleep, allow_sleep, done, second_wait;
static unsigned pause_calls;
static std::atomic<unsigned> processed{0};
template<class T, unsigned N> class unordered_ring_mpsc {
    std::mutex m;
    std::vector<T> events;
public:
    template<class... A> bool emplace(A&&... args) {
        std::lock_guard<std::mutex> lock(m);
        if (events.size() == N) return false;
        events.emplace_back(std::forward<A>(args)...); return true;
    }
    std::vector<T> drain() {
        std::lock_guard<std::mutex> lock(m);
        std::vector<T> out; out.swap(events); return out;
    }
};
static void live_entropy_sources_init(void*) {}
static void live_entropy_sources_deinit(void*) {}
static void live_entropy_sources_feed(int, event_proc_f) {
    std::unique_lock<std::mutex> lock(gate);
    if (!at_feed) {
        at_feed = true; cv.notify_all();
        cv.wait(lock, [] { return allow_feed; });
    }
}
static void tsleep(void*, int, const char*, int) {
    std::unique_lock<std::mutex> lock(gate);
    at_sleep = true; cv.notify_all();
    cv.wait(lock, [] { return allow_sleep; });
}
static void bsd_pause(const char* name, int) {
    if (std::string(name) == "harvest") { tsleep(nullptr, 0, name, 0); return; }
    std::unique_lock<std::mutex> lock(gate);
    if (++pause_calls > 1) second_wait = true;
    cv.notify_all();
    cv.wait(lock, [] { return at_sleep; });
    if (pause_calls > 1) cv.wait(lock, [] { return allow_sleep; });
}
static int kproc_create(void(*)(void*), void*, proc**, int, int, const char*) { return 0; }
[[noreturn]] static void panic(const char*) { std::abort(); }
static void random_set_wakeup_exit(void*) {}
static void kthread_exit() {}
static void random_yarrow_reseed() {}
// KERNEL_CODE
int main() {
    const bool test_stop = TEST_STOP;
    std::thread stopper;
    ring = new ring_t;
    stopping.store(false);
    std::thread worker([] { random_kthread(reinterpret_cast<void*>(+[](harvest*) { ++processed; })); });
    {
        std::unique_lock<std::mutex> lock(gate);
        cv.wait(lock, [] { return at_feed; });
    }
    // Actual worker is now past its drain. Admit an event THEN request flush.
    random_harvestq_internal(1, "x", 1, 0, RANDOM_START);
    std::thread flusher([] {
        FLUSH_CALL;
        std::lock_guard<std::mutex> lock(gate);
        done = true; cv.notify_all();
    });
    // pause entered => the actual flush code has published its request.
    {
        std::unique_lock<std::mutex> lock(gate);
        cv.wait_for(lock, std::chrono::seconds(2), [] { return pause_calls != 0; });
        assert(pause_calls != 0);
        if (test_stop) {
            stopper = std::thread([] {
                observe_stop = true;
                random_harvestq_deinit();
                stop_done = true;
            });
            cv.wait(lock, [] { return stop_attempted; });
            assert(!stop_done && "stop bypassed admitted flush");
        }
        allow_feed = true; cv.notify_all();
        cv.wait(lock, [] { return done || second_wait; });
        assert(!done && "flush acknowledged event inserted after drain");
        assert(processed == 0);
        allow_sleep = true; cv.notify_all();
    }
    flusher.join();
    assert(processed == 1);
    if (test_stop) {
        stopper.join(); worker.join();
        STOP_CHECK
        puts("PASS: admitted flush completes before stop, subsequent flush ENXIO");
        return 0;
    }
    puts("PASS: flush waits for prior admitted event processing");
    fflush(stdout);
    // Worker lifetime is covered by the actual guest, not this scheduling shim.
    std::_Exit(0);
}
