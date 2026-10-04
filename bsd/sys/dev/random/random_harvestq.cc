/*-
 * Copyright (c) 2000-2013 Mark R V Murray
 * Copyright (c) 2013 Arthur Mesh
 * Copyright (c) 2004 Robert N. M. Watson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer
 *    in this position and unchanged.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 */

#include <sys/cdefs.h>
__FBSDID("$FreeBSD$");

#include "opt_random.h"
#include <atomic>

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/eventhandler.h>
#include <sys/kernel.h>
#include <sys/kthread.h>
#ifndef __OSV__
#include <sys/linker.h>
#endif
#include <sys/lock.h>
#include <sys/malloc.h>
#include <sys/mutex.h>
#include <sys/selinfo.h>
#include <sys/sysctl.h>
#include <sys/unistd.h>
#ifndef __OSV__
#include <machine/cpu.h>
#endif
#include <machine/vmparam.h>

#include <dev/random/randomdev.h>
#include <dev/random/randomdev_soft.h>
#include <dev/random/random_adaptors.h>
#include <dev/random/random_harvestq.h>
#include <dev/random/live_entropy_sources.h>

#define RANDOM_FIFO_MAX	1024	/* How many events to queue up */

#ifdef __OSV__
#include <stddef.h>
#include <atomic>
#include <osv/mutex.h>
#include <osv/irqlock.hh>
#include <osv/spinlock.h>
#include <sys/bus.h>
#include <lockfree/unordered_ring_mpsc.hh>
#endif

// Requests are sampled BEFORE draining. An ack covers only that snapshot,
// never a request which arrived after the consumer passed a producer's ring.
static std::atomic<uint64_t> flush_request{0}, flush_ack{0};
static std::atomic<bool> stopping{true}, exited{false};
static mutex flush_mutex;
static np_spinlock admission_lock;

static struct proc *random_kthread_proc;

using ring_t = unordered_ring_mpsc<struct harvest,HARVEST_RING_SIZE>;
ring_t* ring;

static void
random_kthread(void *arg)
{
	event_proc_f entropy_processor = reinterpret_cast<event_proc_f>(arg);

	/* Process until told to stop */
	for (;;) {
        const bool stop = stopping.load(std::memory_order_acquire);
		auto request = flush_request.load(std::memory_order_acquire);
		/*
		 * Grab all the entropy events.
		 * Drain entropy source records into a thread-local
		 * queue for processing while not holding the mutex.
		 */

		/*
		 * Deal with events, if any.
		 * Then transfer the used events back into the empty fifo.
		 */
		for (auto& event : ring->drain()) {
			entropy_processor(&event);
		}

		/*
		 * Do only one round of the hardware sources for now.
		 * Later we'll need to make it rate-adaptive.
		 */
		live_entropy_sources_feed(1, entropy_processor);

		flush_ack.store(request, std::memory_order_release);
		if (stop) {
			break;
		}
		bsd_pause("harvest", hz / 10);
	}
    exited.store(true, std::memory_order_release);
    kthread_exit();
	/* NOTREACHED */
}

void
random_harvestq_init(event_proc_f cb)
{
    static std::atomic<bool> initialized{false};
    if (initialized.exchange(true)) {
        panic("harvest queue reinitialization is not supported");
    }
    exited.store(false, std::memory_order_relaxed);
    flush_request.store(0, std::memory_order_relaxed);
    flush_ack.store(0, std::memory_order_relaxed);
	ring = new ring_t();
    stopping.store(false, std::memory_order_release);

	live_entropy_sources_init(NULL);

	/* Start the hash/reseed thread */
	int error = kproc_create(reinterpret_cast<void(*)(void*)>(random_kthread), reinterpret_cast<void*>(cb),
		&random_kthread_proc, RFHIGHPID, 0, "rand_harvestq"); /* RANDOM_CSPRNG_NAME */

	if (error != 0)
		panic("Cannot create entropy maintenance thread.");
}

void
random_harvestq_deinit(void)
{
    std::lock_guard<mutex> lock(flush_mutex);
    // Rendezvous with every admitted producer. Never wait for the worker
    // with IRQs disabled or while holding admission_lock. The worker samples
    // stop before its final drain, so accepted records are not discarded.
    {
        irq_save_lock_type irq;
        std::lock_guard<irq_save_lock_type> irq_guard(irq);
        std::lock_guard<np_spinlock> guard(admission_lock);
        // All accepted emplaces finished before the worker can see stop.
        stopping.store(true, std::memory_order_release);
    }
    if (!ring) {
        return;
    }
    while (!exited.load(std::memory_order_acquire)) {
        bsd_pause("harvest exit", hz / 10);
    }
	delete ring;
    ring = nullptr;
    // Registry is process-lifetime: exported source registration/feed calls
    // must not race destruction of its lock. Device unload is not supported.
}

/*
 * Entropy harvesting routine.
 * This is supposed to be fast; do not do anything slow in here!
 *
 * It is also illegal (and morally reprehensible) to insert any
 * high-rate data here. "High-rate" is define as a data source
 * that will usually cause lots of failures of the "Lockless read"
 * check a few lines below. This includes the "always-on" sources
 * like the Intel "rdrand" or the VIA Nehamiah "xstore" sources.
 */
bool
random_harvestq_try(u_int64_t somecounter, const void *entropy,
    u_int count, u_int bits, enum esource origin)
{
	KASSERT(origin >= RANDOM_START && origin < ENTROPYSOURCE,
	    ("random_harvest_internal: origin %d invalid\n", origin));

    irq_save_lock_type irq;
    std::lock_guard<irq_save_lock_type> irq_guard(irq);
    std::lock_guard<np_spinlock> guard(admission_lock);
    if (stopping.load(std::memory_order_acquire)) {
        return false;
    }
	return ring->emplace(somecounter, entropy, count, bits, origin);
}

void
random_harvestq_internal(u_int64_t counter, const void *entropy,
    u_int count, u_int bits, enum esource origin)
{
    // Interrupt harvesting is best effort: full rings drop the event, with
    // no credit. Never wait in an interrupt for the consumer to make room.
    (void)random_harvestq_try(counter, entropy, count, bits, origin);
}

int
random_harvestq_flush(void)
{
    std::lock_guard<mutex> lock(flush_mutex);
    if (stopping.load(std::memory_order_acquire)) {
        return ENXIO;
    }
    auto request = flush_request.load(std::memory_order_relaxed) + 1;
    flush_request.store(request, std::memory_order_release);
    while (flush_ack.load(std::memory_order_acquire) != request) {
        bsd_pause("harvest flush", hz / 10);
    }
    return 0;
}
