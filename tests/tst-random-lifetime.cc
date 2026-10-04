/* Copyright (C) 2026 Greg Burd. BSD license; see LICENSE. */
// Destructive dedicated guest: permanently stops RNG harvest worker.
#include <cassert>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>
#include <osv/sched.hh>
#include <osv/irqlock.hh>
#include <sys/param.h>
#include <sys/mutex.h>
#include <dev/random/randomdev.h>
#include <dev/random/randomdev_soft.h>
#include <dev/random/random_adaptors.h>
#include <dev/random/random_harvestq.h>
#include <dev/random/yarrow.h>
#include <drivers/random.hh>

int main()
{
    const uint64_t material = 42;
    std::atomic<bool> started{false}, stop{false}, done{false};
    std::thread watchdog([&] {
        std::this_thread::sleep_for(std::chrono::seconds(8));
        assert(done.load() && "queue teardown/late flush hung");
    });
    // Actual exported direct producer concurrent with full adaptor shutdown,
    // not merely deregistration of the interrupt callback.
    std::thread producer([&] {
        started = true;
        while (!stop.load()) {
            random_harvestq_try(42, &material, sizeof(material), 0, RANDOM_INTERRUPT);
        }
    });
    while (!started.load()) std::this_thread::yield();
    random_adaptor->deinit();
    stop = true;
    producer.join();
    for (int i = 0; i < 100; ++i) {
        assert(!random_harvestq_try(42, &material, sizeof(material), 0, RANDOM_INTERRUPT));
    }
    assert(random_harvestq_flush() == ENXIO);
    random_harvestq_deinit(); // repeated stop is harmless
    // Already exported read/reseed/event functions retain process-lifetime
    // state: shutdown must not destroy a mutex out from under these callers.
    std::vector<std::thread> readers;
    for (int i = 0; i < 4; ++i) {
        readers.emplace_back([&] {
            for (int j = 0; j < 20; ++j) {
                char bytes[32];
                assert(random_adaptor->read(bytes, sizeof(bytes)) == sizeof(bytes));
                random_adaptor->reseed();
                random_yarrow_reseed();
                struct harvest event(42, &material, sizeof(material), 0, RANDOM_INTERRUPT);
                random_process_event(&event);
                randomdev::reseed_on_resume();
            }
        });
    }
    for (auto& reader : readers) reader.join();
    done = true;
    watchdog.join();
    puts("PASS: direct producers drained, late enqueue rejected, late flush ENXIO, persistent output state");
}
