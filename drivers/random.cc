/*-
 * Copyright (c) 2000-2013 Mark R V Murray
 * Copyright (c) 2013 Arthur Mesh <arthurmesh@gmail.com>
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

/*
 * Copyright (C) 2014 Cloudius Systems, Ltd.
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#include "drivers/random.hh"
#include <assert.h>
#include <stdio.h>

#include <osv/device.h>
#include <osv/uio.h>
#include <osv/debug.hh>
#include <osv/clock.hh>
#include <atomic>
#include <osv/kernel_config_core_reseed_on_resume.h>

#include <dev/random/randomdev.h>
#include <dev/random/randomdev_soft.h>
#include <dev/random/random_adaptors.h>
#include <dev/random/random_harvestq.h>
#include <dev/random/live_entropy_sources.h>
#ifdef __aarch64__
#include "cpuid.hh"
#endif

#ifdef __x86_64__
#include "processor.hh"
#endif

namespace randomdev {

#if CONF_core_reseed_on_resume
void reseed_on_resume();
#endif

struct random_device_priv {
    random_device* drv;
};

static random_device_priv *to_priv(device *dev)
{
    return reinterpret_cast<random_device_priv*>(dev->private_data);
}

#ifdef __x86_64__
// Fill @buf from whichever hardware RNG is available (RDRAND or RDSEED).
// Defined below; forward-declared so random_read() can use it for the
// not-yet-seeded fast path.
static int hw_rng_fill(void *buf, int size);
#endif

#if CONF_core_reseed_on_resume
// Low-latency, read-path half of the hypervisor-resume CSPRNG reseed described
// at reseed_on_resume() below. The problem it solves: a full-VM snapshot
// captures the entropy pool and CSPRNG state, so two guests restored from the
// same snapshot would replay an identical OS random stream (duplicate session
// keys, TCP sequence numbers, UUIDs) until something forces a re-key.
//
// Resume is detected in two independent places:
//   1. drivers/kvmclock.cc, in the 1Hz "kvm_wall_clock_sync" thread: a proactive
//      detector that fires within ~1.5s of resume even if nothing ever reads
//      /dev/random. This is the one that covers in-kernel CSPRNG consumers
//      (arc4random()/read_random() for TCP ISNs etc.) which never enter this
//      read path.
//   2. here, in random_read(): a reactive detector that fires immediately on
//      the first /dev/random or getrandom() read after resume, closing the up
//      to ~1.5s window in which detector 1 has not fired yet.
//
// We compare the monotonic uptime clock against the value seen at the previous
// read. Between two back-to-back reads uptime advances by microseconds; a jump
// far larger than any plausible gap between reads (>1.5s, matching the kvmclock
// detector's threshold: this code exists to detect the same event sooner, not
// at a lower threshold) means the guest was paused across a snapshot and
// resumed, so we re-key before serving. Reseeding is skipped on the hot read
// path (back-to-back reads never exceed the threshold) and, in the rare case it
// does fire after a long idle with no resume, an extra re-key is harmless.
static std::atomic<u64> _last_read_uptime{0};
// Set true once randomdev_init() has brought the device (and the harvest ring)
// up, so reseed_on_resume() is a true no-op if a resume is somehow detected
// before that (e.g. with --norandom).
static std::atomic<bool> _reseed_ready{false};

static void reseed_if_resumed()
{
    u64 now = (u64)::clock::get()->uptime();
    u64 prev = _last_read_uptime.exchange(now, std::memory_order_relaxed);
    // Skip the very first read (prev == 0) and only act on a large forward jump.
    // 1.5s matches the kvmclock detector; the purpose of this read-path check is
    // faster detection of the same resume event, not a lower threshold.
    if (prev != 0 && now > prev && (now - prev) > 1500000000ULL) {
        reseed_on_resume();
    }
}
#endif

#ifdef __aarch64__
static int rndr_read(void *, int);   // hardware RNDR read, defined below
#endif

static int
random_read(struct device *dev, struct uio *uio, int ioflags)
{
    int c, error = 0;
    char random_buf[PAGE_SIZE];

#if CONF_core_reseed_on_resume
    reseed_if_resumed();
#endif

    // Blocking logic
    if (!random_adaptor->seeded) {
#if defined(__x86_64__) || defined(__aarch64__)
        // The software CSPRNG has not accumulated enough harvested entropy to
        // seed yet.  If the CPU has a hardware CSPRNG that needs no
        // accumulation window (x86 RDRAND, aarch64 RNDR/FEAT_RNG), satisfy the
        // read directly from it instead of blocking: its output is
        // cryptographically secure, so /dev/{u,}random is usable from the very
        // first read.  Otherwise an early reader -- e.g. a PostgreSQL backend
        // generating its cancel key via pg_strong_random() ->
        // read(/dev/urandom) -- blocks in randomdev_block() -> msleep(PCATCH);
        // with signals unblocked that becomes an EINTR retry loop, and until
        // the adaptor crosses its reseed threshold the read never completes.
        // On x86 this was observed (racily) as "could not generate random
        // cancel key" failing backends at startup.  On aarch64, where there was
        // no hardware path at all before this, the very first postmaster read
        // of /dev/urandom blocked FOREVER and PostgreSQL never reached "ready
        // to accept connections" -- the postmaster thread sat in
        // sys_read -> device_read -> randomdev::random_read ->
        // randomdev_block -> _msleep -> sched::thread::wait with every CPU
        // idle.  Pre-existing OSv startup race; independent of fork.
#ifdef __x86_64__
        // RDRAND *or* RDSEED: RDSEED is a true entropy source and equally
        // cryptographically secure, and native Nitro reports rdrand false while
        // offering rdseed, so requiring RDRAND alone still blocked there.
        if (processor::features().rdrand || processor::features().rdseed) {
#endif
#ifdef __aarch64__
        if (processor::features().rndr) {
#endif
            while (uio->uio_resid > 0 && !error) {
                c = std::min(uio->uio_resid, static_cast<long int>(PAGE_SIZE));
                // the hardware read wants a multiple-of-8 length; round up in
                // the page buffer and copy out only what the caller asked for.
                int c8 = (c + 7) & ~7;
#ifdef __x86_64__
                int got = hw_rng_fill(static_cast<void *>(random_buf), c8);
#endif
#ifdef __aarch64__
                int got = rndr_read(static_cast<void *>(random_buf), c8);
#endif
                if (got <= 0) { error = EIO; break; }
                error = uiomove(random_buf, std::min(c, got), uio);
            }
            return error;
        }
#endif
        error = (*random_adaptor->block)(ioflags);
    }

    if (!error) {
        while (uio->uio_resid > 0 && !error) {
            c = std::min(uio->uio_resid, static_cast<long int>(PAGE_SIZE));
            c = (*random_adaptor->read)(static_cast<void *>(random_buf), c);
            error = uiomove(random_buf, c, uio);
        }

        // Finished reading; let the source know so it can do some
        // optional housekeeping */
        (*random_adaptor->read)(nullptr, 0);
    }

    return error;
}

static int
random_write(struct device *dev, struct uio *uio, int ioflags)
{
    // We used to allow this to insert userland entropy.
    // We don't any more because (1) this so-called entropy
    // is usually lousy and (b) its vaguely possible to
    // mess with entropy harvesting by overdoing a write.
    // Now we just ignore input like /dev/null does.
    uio->uio_resid = 0;

    return 0;
}

static struct devops random_device_devops {
    no_open,
    no_close,
    random_read,
    random_write,
    no_ioctl,
    no_devctl,
};

struct driver random_device_driver = {
    "random",
    &random_device_devops,
    sizeof(struct random_device_priv),
};

//
// Intel DRNG, RDRAND / RDSEED: hardware source of entropy.
// Implementation based on the following Intel manual:
// Intel(r) Digital Random Number Generator (DRNG)
//
#ifdef __x86_64__
static int drng_read(void *, int);

// The constant below is based on the aforementioned Intel manual.
// It recommends that RDRAND users should retry 10 times when the
// instruction failed to work as expected.
static constexpr int rdrand_retries_max = 10;

static struct random_hardware_source drng = {
    "intel drng, rdrand",
    RANDOM_PURE_RDRAND,
    &drng_read,
};

static inline bool rdrand_with_retries(uint64_t *data)
{
    for (auto retry = 0; retry <= rdrand_retries_max; retry++) {
        if (processor::rdrand(data)) {
            return true;
        }
    }
    return false;
}

// RDSEED is a true (non-deterministic) hardware entropy source and is present
// on every CPU that OSv runs on natively that lacks a usable RDRAND path
// (e.g. some virtualized Nitro guests report rdrand=false but expose rdseed).
// RDSEED can transiently fail more often than RDRAND under contention, so it
// gets a larger retry budget.
static constexpr int rdseed_retries_max = 100;

static inline bool rdseed_with_retries(uint64_t *data)
{
    for (auto retry = 0; retry <= rdseed_retries_max; retry++) {
        if (processor::rdseed(data)) {
            return true;
        }
    }
    return false;
}

// Fill @buf from whichever hardware RNG is available, preferring RDRAND (a
// hardware CSPRNG that is fast and rarely stalls) and falling back to RDSEED.
// Returns the number of bytes produced (a multiple of 8), 0 if neither works.
static int hw_rng_fill(void *buf, int size)
{
    uint64_t *dest = static_cast<uint64_t *>(buf);
    uint64_t data;
    unsigned qwords, qwords_to_read;
    bool have_rdrand = processor::features().rdrand;
    bool have_rdseed = processor::features().rdseed;

    assert((size & (sizeof(uint64_t) - 1)) == 0);
    qwords_to_read = size / sizeof(uint64_t);

    for (qwords = 0; qwords < qwords_to_read; qwords++) {
        bool ok = false;
        if (have_rdrand) {
            ok = rdrand_with_retries(&data);
        }
        if (!ok && have_rdseed) {
            ok = rdseed_with_retries(&data);
        }
        if (!ok) {
            break;
        }
        *dest++ = data;
    }
    return qwords * sizeof(uint64_t);
}

static int
drng_read(void *buf, int size)
{
    return hw_rng_fill(buf, size);
}
#endif

//
// Arm FEAT_RNG, RNDR: architectural hardware source of entropy.
// RNDR returns a 64-bit random number from a DRBG seeded by a true entropy
// source, with NZCV.C=0 on success (C=1 means the RNG could not return a
// number in reasonable time, and the result must be discarded).
//
#ifdef __aarch64__
static int rndr_read(void *, int);

// Mirrors the x86 RDRAND retry policy: RNDR can transiently fail to deliver
// while the underlying entropy source catches up, so retry a bounded number of
// times before giving up.
static constexpr int rndr_retries_max = 10;

static struct random_hardware_source arm_rndr = {
    "arm rndr",
    RANDOM_PURE_RDRAND,
    &rndr_read,
};

static inline bool rndr_with_retries(uint64_t *data)
{
    for (auto retry = 0; retry <= rndr_retries_max; retry++) {
        uint64_t val;
        uint64_t fail;
        // mrs <x>, RNDR (S3_3_C2_C4_0); PSTATE.C is set if the read failed.
        asm volatile("mrs %0, s3_3_c2_c4_0\n\t"
                     "cset %1, cs\n\t"
                     : "=r"(val), "=r"(fail)
                     :
                     : "cc");
        if (!fail) {
            *data = val;
            return true;
        }
    }
    return false;
}

static int
rndr_read(void *buf, int size)
{
    uint64_t *dest = static_cast<uint64_t *>(buf);
    uint64_t data;
    unsigned qwords, qwords_to_read;

    assert((size & (sizeof(uint64_t) - 1)) == 0);
    qwords_to_read = size / sizeof(uint64_t);

    for (qwords = 0; qwords < qwords_to_read; qwords++) {
        if (!rndr_with_retries(&data)) {
            // Handle the unlikely case where RNDR failed after all retries.
            break;
        }

        *dest++ = data;
    }

    return qwords * sizeof(uint64_t);
}
#endif

random_device::random_device()
{
    struct random_device_priv *prv;

#ifdef __x86_64__
    // Expose a hardware entropy source if the CPU has RDRAND (a hardware
    // CSPRNG) or RDSEED (a true entropy source).  Some native/virtualized
    // guests report rdrand=false but do expose rdseed, so register on either.
    if (processor::features().rdrand || processor::features().rdseed) {
        live_entropy_source_register(&drng);
    }
#endif
#ifdef __aarch64__
    if (processor::features().rndr) {
        live_entropy_source_register(&arm_rndr);
    }
#endif
    if (live_entropy_sources_empty()) {
        debug("Warning: No hardware source of entropy available to your "
            "platform,\n\tCSPRNG will rely on software source of entropy to "
            "provide high-quality randomness.\n");
    }
    (random_adaptor->init)();

    // Boot-time seed fallback.  Without a hardware RNG (no RDRAND/RDSEED) AND
    // without a virtio-rng device, the software CSPRNG never accumulates
    // enough harvested entropy to cross its reseed threshold, so
    // randomdev_block() blocks forever and every /dev/urandom reader (e.g. a
    // PostgreSQL backend's pg_strong_random() cancel key) fails.  This is the
    // case on native Nitro guests.  Seed the CSPRNG from the CPU timestamp
    // counter's low-order jitter and explicitly unblock so reads complete.
    // (When RDRAND/RDSEED exist, random_read() serves those reads straight
    // from hardware and never reaches the block path, so this is a pure
    // last-resort for the no-hardware-entropy native case.)
    if (live_entropy_sources_empty() && !random_adaptor->seeded) {
#ifdef __x86_64__
        for (int i = 0; i < HARVEST_RING_SIZE; i++) {
            uint64_t sample = processor::ticks();
            random_harvestq_internal(sample, &sample, sizeof(sample),
                sizeof(sample) * 8, RANDOM_START);
        }
#endif
        randomdev_unblock();
    }

    // Create random
    _random_dev = device_create(&random_device_driver, "random", D_CHR);
    prv = to_priv(_random_dev);
    prv->drv = this;

    // Create urandom as a sort of alias to random
    _urandom_dev = device_create(&random_device_driver, "urandom", D_CHR);
    prv = to_priv(_urandom_dev);
    prv->drv = this;
}

random_device::~random_device()
{
#ifdef __x86_64__
    if (processor::features().rdrand || processor::features().rdseed) {
        live_entropy_source_deregister(&drng);
    }
#endif
#ifdef __aarch64__
    if (processor::features().rndr) {
        live_entropy_source_deregister(&arm_rndr);
    }
#endif
    (random_adaptor->deinit)();

    device_destroy(_random_dev);
    device_destroy(_urandom_dev);
}

void randomdev_init()
{
    new random_device();
    debugf("random: <%s> initialized\n", random_adaptor->ident);
    // LEVER PROOF (printf, not debugf: debugf is verbose-gated and silent).
    // The native RNG blocker was "rdrand reported FALSE, no virtio-rng"; this
    // line makes the RESOLVED capability auditable per arm from the console.
#ifdef __x86_64__
    printf("RNGPROOF rdrand=%d rdseed=%d hwsrc_empty=%d seeded=%d\n",
        processor::features().rdrand ? 1 : 0,
        processor::features().rdseed ? 1 : 0,
        live_entropy_sources_empty() ? 1 : 0,
        random_adaptor->seeded ? 1 : 0);
#endif
#if CONF_core_reseed_on_resume
    // Mark the harvest ring up, so a resume detected before this point is a
    // true no-op (see reseed_if_resumed()).
    _reseed_ready.store(true, std::memory_order_release);
#endif
}

#if CONF_core_reseed_on_resume
// Force the CSPRNG to re-key after a hypervisor resume so that two guests
// restored from the SAME snapshot do not keep producing identical OS random
// output. A full-VM snapshot captures the entire entropy pool and CSPRNG state,
// so without an explicit reseed every clone would replay the exact same random
// stream. This is a real correctness and security problem for a cloned fleet
// (duplicated session keys, TCP sequence numbers, UUIDs, and so on).
//
// We mix in values that are guaranteed to differ between two clones even when
// there is no live hardware entropy source (no RDRAND, no virtio-rng): the
// wall-clock time the hypervisor handed us on resume differs per clone because
// each clone is resumed at a distinct host wall-clock instant, and the TSC on
// resume differs as well. We feed that unique material into the harvest queue
// as DIVERGENCE material only (bits == 0), so it is hashed into the pool to
// force the two clones apart but is NOT credited as entropy - it must never be
// able to advance Yarrow's counters or unblock /dev/random on its own, since it
// is predictable low-quality data, not real entropy. RDRAND/RDSEED and any
// virtio-rng source continue to feed the pool as before. After mixing we
// command an explicit reseed so the re-key takes effect immediately rather than
// only after the next periodic harvest round.
//
// This runs ONLY when a resume has actually been detected (see the two callers:
// the 1Hz "kvm_wall_clock_sync" thread in drivers/kvmclock.cc, and
// reseed_if_resumed() on the /dev/random read path above), so a normally-
// running or freshly-booted guest that is never resumed follows exactly the
// same code path as before.
void reseed_on_resume()
{
    // No-op until the random device has actually been initialized. random_adaptor
    // is always non-null (it points at the static soft CSPRNG context), so that
    // alone is not enough: with --norandom, or if a resume were somehow detected
    // before randomdev_init() ran, the harvest ring would not exist yet and
    // random_harvestq_internal() would dereference it. _reseed_ready is set true
    // only at the end of randomdev_init(), after random_harvestq_init().
    if (!random_adaptor || !_reseed_ready.load(std::memory_order_acquire)) {
        return;
    }

    // Per-resume unique material. Each field differs between two clones that
    // were resumed from the same snapshot at different host wall-clock instants.
    struct {
        u64 wall_ns;
        u64 tsc;
        u64 uptime_ns;
    } seed;
    seed.wall_ns = (u64)::clock::get()->time();
    seed.uptime_ns = (u64)::clock::get()->uptime();
#ifdef __x86_64__
    seed.tsc = processor::rdtsc();
#else
    seed.tsc = seed.uptime_ns;
#endif

    // Mix the unique material in with a zero entropy-bit credit (divergence, not
    // entropy), then force an explicit reseed so the re-key is effective before
    // the next read. Any live hardware source (RDRAND / virtio-rng) is drained
    // by the reseed itself.
    random_harvestq_internal(seed.tsc, &seed, sizeof(seed),
                             0, RANDOM_PURE_RDRAND);
    if (random_adaptor->reseed) {
        (random_adaptor->reseed)();
    }
}
#endif

}
