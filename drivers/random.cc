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

#include <osv/device.h>
#include <osv/uio.h>
#include <osv/debug.hh>

#include <dev/random/randomdev.h>
#include <dev/random/randomdev_soft.h>
#include <dev/random/random_adaptors.h>
#include <dev/random/live_entropy_sources.h>

namespace randomdev {

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

static int
random_read(struct device *dev, struct uio *uio, int ioflags)
{
    int c, error = 0;
    char random_buf[PAGE_SIZE];

    // Blocking logic
    if (!random_adaptor->seeded) {
#ifdef __x86_64__
        // The software CSPRNG has not accumulated enough harvested entropy to
        // seed yet.  If the CPU has a hardware RNG (RDRAND, a hardware CSPRNG,
        // or RDSEED, a true entropy source), satisfy the read directly from it
        // instead of blocking: both are cryptographically secure, so
        // /dev/{u,}random is usable from the very first read.  Otherwise an
        // early reader -- e.g. a PostgreSQL backend generating its cancel key
        // via pg_strong_random() -> read(/dev/urandom) -- blocks in
        // randomdev_block() forever on a native guest with no entropy-
        // harvesting source and no virtio-rng (observed on native Nitro:
        // rdrand reported false, no virtio-rng, adaptor never crosses its
        // reseed threshold -> "could not generate random cancel key").
        if (processor::features().rdrand || processor::features().rdseed) {
            while (uio->uio_resid > 0 && !error) {
                c = std::min(uio->uio_resid, static_cast<long int>(PAGE_SIZE));
                // hw_rng_fill wants a multiple-of-8 length; round up in the
                // page buffer and copy out only what the caller asked for.
                int c8 = (c + 7) & ~7;
                int got = hw_rng_fill(static_cast<void *>(random_buf), c8);
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
    (random_adaptor->deinit)();

    device_destroy(_random_dev);
    device_destroy(_urandom_dev);
}

void randomdev_init()
{
    new random_device();
    debugf("random: <%s> initialized\n", random_adaptor->ident);
}

}
