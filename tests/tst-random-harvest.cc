/* Copyright (C) 2026 Greg Burd. BSD license; see LICENSE. */
// Opt-in destructive test: one CPU, no live RNG; harvesting stays disabled.
#undef NDEBUG
#include <cassert>
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
#include <dev/random/live_entropy_sources.h>
#include <fcntl.h>

int main()
{
    assert(sched::cpus.size() == 1 && live_entropy_sources_empty());
    randomdev_deinit_harvester();
    random_adaptor->reseed();
    mtx_lock(&random_reseed_mtx);
    random_adaptor->seeded = 1;
    mtx_unlock(&random_reseed_mtx);
    random_adaptor->reseed();
    mtx_lock(&random_reseed_mtx);
    random_adaptor->seeded = 0;
    mtx_unlock(&random_reseed_mtx);
    const uint64_t material = 123;
    // IRQ-off on the only CPU excludes consumer. Admission is bounded;
    // overflow must return false, never wait or credit rejected material.
    {
        irq_save_lock_type irq;
        std::lock_guard<irq_save_lock_type> guard(irq);
        for (unsigned i = 0; i < HARVEST_RING_SIZE; ++i) {
            assert(random_harvestq_try(i, &material, sizeof(material), 0, RANDOM_INTERRUPT));
        }
        assert(!random_harvestq_try(1, &material, sizeof(material), 1000, RANDOM_INTERRUPT));
    }
    assert(random_harvestq_flush() == 0);
    assert(random_adaptor->block(O_NONBLOCK) == EWOULDBLOCK);
    puts("CONTROL: bounded full queue rejects credited event; flush remains unseeded");

    // Completion must cover admitted events, and overlapping callers must
    // not steal another caller's acknowledgment.
    assert(random_harvestq_try(2, &material, sizeof(material), 128, RANDOM_INTERRUPT));
    assert(random_harvestq_try(3, &material, sizeof(material), 128, RANDOM_INTERRUPT));
    std::vector<std::thread> threads;
    for (int i = 0; i < 4; ++i) {
        threads.emplace_back([] { assert(random_harvestq_flush() == 0); });
    }
    for (auto& thread : threads) thread.join();
    assert(random_adaptor->block(O_NONBLOCK) == 0);
    puts("PASS: concurrent actual queue flushes process prior admitted credit");
}
